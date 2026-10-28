import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../events/data/event_repository.dart';
import '../domain/response_action_schema.dart';

class ResponseActionReceipt {
  const ResponseActionReceipt({
    required this.entityId,
    required this.status,
    this.savedSchedule,
  });
  final String entityId;
  final String status;
  final Map<String, dynamic>? savedSchedule;
  bool get removed => status == 'removed';
  String get message => switch (status) {
    'removed' => '已创建，之后已删除',
    'synced' => '已同步',
    'conflict' || 'failed' => '已保存在本机，同步需要处理',
    _ => '已保存在本机，等待同步',
  };
}

/// Uses the existing local-first creation path and atomically stores its receipt.
class ResponseActionService {
  ResponseActionService(this.events);
  final EventRepository events;
  AppDatabase get database => events.database;

  Future<String> _key(String scope, Map<String, dynamic> item) async {
    final keys = item.keys.toList()..sort();
    final canonical = {for (final key in keys) key: item[key]};
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([
          await events.config.serverUrl(),
          await events.config.sessionUsername(),
          scope,
          canonical,
        ]),
      ),
    );
    return 'response_ui.action.$digest';
  }

  Future<ResponseActionReceipt?> lookup(
    String scope,
    Map<String, dynamic> item,
  ) async {
    final key = await _key(scope, item);
    return _lookupKey(key);
  }

  Future<ResponseActionReceipt?> _lookupKey(String key) async {
    final stored = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.equals(key))).getSingleOrNull();
    if (stored == null) return null;
    final value = jsonDecode(stored.value) as Map<String, dynamic>;
    final id = value['entityId'] as String;
    if (value['kind'] == 'task') {
      final row = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      return ResponseActionReceipt(
        entityId: id,
        status: row == null || row.deletedAt != null
            ? 'removed'
            : await _status(id, row.syncStatus),
      );
    }
    final row = await (database.select(
      database.calendarEvents,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    return ResponseActionReceipt(
      entityId: id,
      status: row == null || row.deletedAt != null
          ? 'removed'
          : await _status(id, row.syncStatus),
      savedSchedule: row == null
          ? null
          : {
              'title': row.title,
              'startAt': row.startAt,
              'endAt': row.endAt,
              'notes': row.description,
              'location': row.location,
            },
    );
  }

  Future<String> _status(String id, String status) async {
    if (status == 'synced') return status;
    final mutation =
        await (database.select(database.outboxMutations)
              ..where((row) => row.entityId.equals(id))
              ..orderBy([(row) => OrderingTerm.desc(row.id)])
              ..limit(1))
            .getSingleOrNull();
    return const {'conflict', 'failed'}.contains(mutation?.status)
        ? mutation!.status
        : status;
  }

  Future<ResponseActionReceipt> create(
    String scope,
    Map<String, dynamic> original, {
    Map<String, dynamic>? overrides,
  }) async {
    // Keep the original payload as the receipt identity, including legacy keys.
    original = Map<String, dynamic>.of(original);
    final allowed = original['kind'] == 'schedule'
        ? const {'title', 'startAt', 'endAt', 'notes', 'location'}
        : const {'title', 'due', 'notes'};
    final item = {...original, ...?overrides};
    if (scope.isEmpty ||
        (overrides != null && !overrides.keys.every(allowed.contains)) ||
        !validateActionResponseBlock({
          'type': 'actions',
          'items': [original],
        }) ||
        !validateActionResponseBlock({
          'type': 'actions',
          'items': [item],
        })) {
      throw ArgumentError('Invalid response action');
    }
    var identityChanged = false;
    Future<void> invalidate() async {
      identityChanged = true;
    }

    void requireIdentity() {
      if (identityChanged) {
        throw StateError('Identity changed while creating action');
      }
    }

    events.config.addIdentityListener(invalidate);
    try {
      final key = await _key(scope, original);
      requireIdentity();
      return await database.transaction(() async {
        final existing = await _lookupKey(key);
        requireIdentity();
        if (existing != null) return existing;
        final previous =
            await (database.select(database.outboxMutations)
                  ..orderBy([(row) => OrderingTerm.desc(row.id)])
                  ..limit(1))
                .getSingleOrNull();
        if (item['kind'] == 'task') {
          await events.createTask(
            title: item['title'] as String,
            notes: item['notes'] as String?,
            due: item['due'] as String?,
          );
        } else {
          await events.createCalendarEvent(
            title: item['title'] as String,
            startAt: DateTime.parse(item['startAt'] as String),
            endAt: DateTime.parse(item['endAt'] as String),
            description: item['notes'] as String?,
            location: item['location'] as String?,
          );
        }
        requireIdentity();
        final mutation =
            await (database.select(database.outboxMutations)
                  ..where(
                    (row) =>
                        row.id.isBiggerThanValue(previous?.id ?? 0) &
                        row.entityType.equals(item['kind'] as String) &
                        row.operation.equals('create'),
                  )
                  ..orderBy([(row) => OrderingTerm.desc(row.id)])
                  ..limit(1))
                .getSingle();
        await database
            .into(database.syncMetadata)
            .insert(
              SyncMetadataCompanion.insert(
                key: key,
                value: jsonEncode({
                  'kind': item['kind'],
                  'entityId': mutation.entityId,
                }),
              ),
            );
        final receipt = await _lookupKey(key);
        if (receipt == null || receipt.removed) {
          throw StateError('Created item could not be read back');
        }
        requireIdentity();
        return receipt;
      });
    } finally {
      events.config.removeIdentityListener(invalidate);
    }
  }
}
