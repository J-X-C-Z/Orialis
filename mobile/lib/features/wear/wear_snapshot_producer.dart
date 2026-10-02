import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../../core/database/app_database.dart';
import 'wear_protocol.dart';
import 'wear_account_snapshot_source.dart';

/// Read-only projection; authenticated server snapshots prove account scope,
/// while shared mobile database previews do not. Neither proves a companion
/// handshake, which is checked independently by the connection manager.
class WearSnapshotPreview {
  const WearSnapshotPreview({
    required this.snapshot,
    required this.included,
    required this.total,
    required this.bytes,
    required this.updatedAt,
    this.accountScopeVerified = false,
  });

  final Map<String, Object?> snapshot;
  final Map<String, int> included, total;
  final int bytes;
  final DateTime updatedAt;
  bool get truncated => included.keys.any((key) => included[key] != total[key]);
  String get sourceLabel =>
      accountScopeVerified ? '当前账号服务端 · 只读副本' : '手机本地数据库 · 未验证账号归属';
  final bool accountScopeVerified;
}

class WearSnapshotProducer {
  WearSnapshotProducer(this.database, this.config);
  final AppDatabase database;
  final AppConfig config;
  static const candidateLimit = 64;

  Future<WearSnapshotPreview> read() async {
    // The manager captures its generation before calling this asynchronous
    // method. Only the non-secret profile observations enter the projection.
    final account = await WearAccountSnapshotSource(config).read();
    final username = account?.username ?? await config.sessionUsername();
    final signedIn = account != null || await config.sessionToken() != null;
    final server = Uri.tryParse(account?.serverUrl ?? await config.serverUrl());
    final now = DateTime.now();
    final local = now.toLocal();
    final today =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final total = <String, int>{};
    final candidates = <String, List<Map<String, Object?>>>{};

    // A successful authenticated server read is independent of the shared DB.
    // Local fallback reads four tables consistently without modifying sync state.
    if (account != null) {
      for (final entry in account.collections.entries) {
        total[entry.key] = entry.value.length;
        candidates[entry.key] = entry.value.take(candidateLimit).toList();
      }
    } else {
      await database.transaction(() async {
        Future<int> count<T extends Table, D>(
          TableInfo<T, D> table,
          Expression<bool> active,
        ) async {
          final amount = countAll();
          final query = database.selectOnly(table)
            ..addColumns([amount])
            ..where(active);
          return (await query.getSingle()).read(amount) ?? 0;
        }

        total['tasks'] = await count(
          database.tasks,
          database.tasks.deletedAt.isNull(),
        );
        total['schedules'] = await count(
          database.calendarEvents,
          database.calendarEvents.deletedAt.isNull(),
        );
        total['projects'] = await count(
          database.projects,
          database.projects.deletedAt.isNull(),
        );
        total['milestones'] = await count(
          database.projectMilestones,
          database.projectMilestones.deletedAt.isNull(),
        );

        final tasks =
            await (database.select(database.tasks)
                  ..where((r) => r.deletedAt.isNull())
                  ..orderBy([
                    (r) => OrderingTerm(expression: r.manualPosition.isNull()),
                    (r) => OrderingTerm(expression: r.manualPosition),
                    (r) => OrderingTerm(expression: r.due),
                    (r) => OrderingTerm(expression: r.id),
                  ])
                  ..limit(candidateLimit))
                .get();
        candidates['tasks'] = tasks
            .map(
              (r) => <String, Object?>{
                'id': r.id,
                'title': r.title,
                'notes': r.notes,
                'due': r.due,
                'dueTime': r.dueTime,
                'important': r.important,
                'urgent': r.urgent,
                'completed': r.completed,
                'reminderMinutes': r.reminderMinutes,
                'recurrence': r.recurrence,
                'projectId': r.projectId,
                'parentTaskId': r.parentTaskId,
                'scheduleId': r.scheduleId,
                'manualPosition': r.manualPosition,
              },
            )
            .toList();
        final schedules =
            await (database.select(database.calendarEvents)
                  ..where((r) => r.deletedAt.isNull())
                  ..orderBy([
                    (r) => OrderingTerm(expression: r.startAt),
                    (r) => OrderingTerm(expression: r.id),
                  ])
                  ..limit(candidateLimit))
                .get();
        candidates['schedules'] = schedules
            .map(
              (r) => <String, Object?>{
                'id': r.id,
                'title': r.title,
                'description': r.description,
                'location': r.location,
                'startAt': r.startAt,
                'endAt': r.endAt,
                'allDay': r.allDay,
                'important': r.important,
                'reminderMinutes': r.reminderMinutes,
              },
            )
            .toList();
        final projects =
            await (database.select(database.projects)
                  ..where((r) => r.deletedAt.isNull())
                  ..orderBy([
                    (r) => OrderingTerm(expression: r.manualPosition.isNull()),
                    (r) => OrderingTerm(expression: r.manualPosition),
                    (r) => OrderingTerm(expression: r.createdAt),
                    (r) => OrderingTerm(expression: r.id),
                  ])
                  ..limit(candidateLimit))
                .get();
        candidates['projects'] = projects
            .map(
              (r) => <String, Object?>{
                'id': r.id,
                'name': r.name,
                'goal': r.goal,
                'description': r.description,
                'status': r.status,
                'due': r.due,
                'nextActionTaskId': r.nextActionTaskId,
                'manualPosition': r.manualPosition,
              },
            )
            .toList();
        final milestones =
            await (database.select(database.projectMilestones)
                  ..where((r) => r.deletedAt.isNull())
                  ..orderBy([
                    (r) => OrderingTerm(expression: r.projectId),
                    (r) => OrderingTerm(expression: r.position),
                    (r) => OrderingTerm(expression: r.id),
                  ])
                  ..limit(candidateLimit))
                .get();
        candidates['milestones'] = milestones
            .map(
              (r) => <String, Object?>{
                'id': r.id,
                'projectId': r.projectId,
                'title': r.title,
                'due': r.due,
                'completed': r.completed,
                'position': r.position,
              },
            )
            .toList();
      });
    }

    final included = {for (final key in total.keys) key: 0};
    final collections = {
      for (final key in total.keys) key: <Map<String, Object?>>[],
    };
    final coverage = <String, Object?>{
      for (final key in total.keys) key: {'included': 0, 'total': total[key]},
      // Reserve the longer Boolean spelling while building within the budget.
      'truncated': false,
    };
    final organizer = <String, Object?>{
      'schemaVersion': 1,
      'today': today,
      // Current phone display offset, not an IANA timezone/DST rule.
      'utcOffsetMinutes': local.timeZoneOffset.inMinutes,
      ...collections,
      'profile': {
        'displayName': signedIn ? username : null,
        'signedIn': signedIn,
        'serverLabel': server?.host.isNotEmpty == true ? server!.host : null,
      },
      // SyncEngine exposes no persisted completion time/current state here.
      // Row syncStatus does not prove a completed synchronization.
      'sync': {'status': 'unknown', 'lastSyncAt': null},
      'coverage': coverage,
    };
    final snapshot = <String, Object?>{
      'transferId': const Uuid().v4(),
      'revision': now.microsecondsSinceEpoch,
      'view': {
        'dataState': account != null ? 'live' : 'stale',
        'updatedAt': now.toUtc().toIso8601String(),
        'states': {
          'phone': 'unknown',
          'orialis': 'unknown',
          'target': 'unknown',
        },
        'organizer': organizer,
      },
    };
    int bytes() => utf8.encode(jsonEncode(snapshot)).length;
    if (bytes() > WearProtocol.maxSnapshotBytes) {
      throw const FormatException('profile exceeds snapshot budget');
    }
    // Round-robin leaves room for each phone domain. Oversized records are
    // omitted whole, never silently shortened or converted to another domain.
    for (var index = 0; index < candidateLimit; index++) {
      for (final key in total.keys) {
        final rows = candidates[key]!;
        if (index >= rows.length) continue;
        collections[key]!.add(rows[index]);
        final next = included[key]! + 1;
        coverage[key] = {'included': next, 'total': total[key]};
        if (bytes() <= WearProtocol.maxSnapshotBytes) {
          included[key] = next;
        } else {
          collections[key]!.removeLast();
          coverage[key] = {'included': included[key], 'total': total[key]};
        }
      }
    }
    coverage['truncated'] = total.keys.any(
      (key) => included[key] != total[key],
    );
    return WearSnapshotPreview(
      snapshot: snapshot,
      included: included,
      total: total,
      bytes: bytes(),
      updatedAt: now,
      accountScopeVerified: account != null,
    );
  }
}
