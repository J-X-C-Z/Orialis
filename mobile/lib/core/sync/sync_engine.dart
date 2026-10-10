import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../config/app_config.dart';
import '../attachments/attachment_bridge.dart';
import '../database/app_database.dart';
import '../network/orialis_api_client.dart';
import 'outbox_store.dart';

part 'project_sync_handler.dart';
part 'chat_sync_handler.dart';
part 'task_schedule_sync_handler.dart';
part 'sync_state_presentation.dart';

enum SyncState { idle, syncing, offline, authRequired, conflict, error }

class SyncEngine {
  SyncEngine({
    required this.database,
    required this.config,
    this.apiClient,
    this.includeChat = true,
    this.requireSession = false,
  });

  final bool includeChat;
  final bool requireSession;
  final AppDatabase database;
  final AppConfig config;
  final OrialisApiClient? apiClient;

  // Reused across sync rounds so each run does not rebuild Dio, interceptors,
  // or outbox helpers just to push a handful of rows.
  OrialisApiClient? _ownedApi;
  OutboxStore? _outbox;
  Set<String>? _serverCapabilities;

  OutboxStore get _outboxStore => _outbox ??= OutboxStore(database);

  Future<OrialisApiClient> _resolveApi() async {
    final existing = apiClient ?? _ownedApi;
    if (existing != null) return existing;
    final baseUrl = await config.serverUrl();
    final deviceId = await config.deviceId();
    return _ownedApi ??= OrialisApiClient(
      baseUrl: baseUrl,
      deviceId: deviceId,
      config: config,
    );
  }

  Future<SyncState> syncOnce() async {
    try {
      if (requireSession && await config.sessionToken() == null) {
        return SyncState.authRequired;
      }
      final api = await _resolveApi();
      _serverCapabilities = null;
      final outbox = _outboxStore;
      await outbox.recoverInFlight();
      await outbox.recoverAcknowledgedEntities();
      // A task can reference a schedule, and a child can reference a task.
      // Upload schedules before tasks; _pushTasks uploads roots before children.
      await Future.wait([
        if (includeChat) _pushConversations(api),
        _pushCalendarEvents(api),
      ]);
      await _pushTasks(api);
      if (includeChat) {
        await _pullConversations(api);
        await Future.wait([_pushMessages(api), _pullMessages(api)]);
      }
      await _pull(api);
      await _pushTasks(api, includeDerivedCompletionMutations: true);
      await _pushProjects(api);
      await _pushProjectMilestones(api);
      return SyncState.idle;
    } on _RemoteMutationConflict {
      return SyncState.conflict;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) return SyncState.authRequired;
      if (error.response?.statusCode == 409) return SyncState.conflict;
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return SyncState.offline;
      }
      return SyncState.error;
    } catch (_) {
      return SyncState.error;
    }
  }

  static const _snapshotKey = 'projectMilestoneSnapshotVersion';

  Future<void> _pull(OrialisApiClient api) async {
    final initialized = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.equals(_snapshotKey))).getSingleOrNull();
    final savedCursor = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.equals('serverCursor'))).getSingleOrNull();
    final savedCursorValue = int.tryParse(savedCursor?.value ?? '');
    // v6 clients may already have skipped Project/Milestone events. A separate
    // bootstrap marker repairs those databases even when their cursor is nonzero.
    if (initialized?.value != '1' ||
        savedCursorValue == null ||
        savedCursorValue < 0) {
      await applySnapshot(await api.syncSnapshot());
    }
    var cursor = await _readCursor();
    var recoveredExpiredCursor = false;
    while (true) {
      late final Map<String, dynamic> response;
      try {
        response = await api.syncEvents(after: cursor);
      } on DioException catch (error) {
        if (error.response?.statusCode != 410 || recoveredExpiredCursor) {
          rethrow;
        }
        await applySnapshot(await api.syncSnapshot());
        cursor = await _readCursor();
        recoveredExpiredCursor = true;
        continue;
      }
      await applySyncEvents(response);
      final events = response['events'] as List<dynamic>;
      final nextCursor = _nonNegativeInt(response['nextCursor'], 'next cursor');
      if (events.isEmpty || nextCursor == cursor) break;
      cursor = nextCursor;
    }
  }

  /// Reconcile all snapshot collections atomically without queuing local writes.
  /// Pending rows and local revisions survive; missing synced rows become local
  /// tombstones. Fetching is outside the transaction, applying and cursor are not.
  Future<void> applySnapshot(Map<String, dynamic> snapshot) async {
    final cursor = _nonNegativeInt(snapshot['cursor'], 'snapshot cursor');
    final collections = <String, List<Map<String, dynamic>>>{
      for (final entry in {
        'project': 'projects',
        'project_milestone': 'milestones',
        'task': 'tasks',
        'calendar_event': 'calendarEvents',
      }.entries)
        entry.key: (snapshot[entry.value] as List<dynamic>)
            .map((raw) => Map<String, dynamic>.from(raw as Map))
            .toList(),
    };
    await database.transaction(() async {
      if (cursor < await _readCursor()) {
        throw const FormatException('snapshot cursor moved backwards');
      }
      for (final entry in collections.entries) {
        final ids = <String>{};
        for (final value in entry.value) {
          if (!ids.add(value['id'] as String)) {
            throw const FormatException('duplicate snapshot entity');
          }
          await _applyRemoteEvent({
            'entityType': entry.key,
            'entityId': value['id'],
            'entityVersion': value['version'],
            'operation': 'upsert',
            'tombstone': false,
            'payloadJson': jsonEncode(value),
          });
        }
        await _removeMissingSnapshotRows(entry.key, ids);
      }
      await _writeCursor(cursor);
      await database
          .into(database.syncMetadata)
          .insertOnConflictUpdate(
            SyncMetadataCompanion.insert(key: _snapshotKey, value: '1'),
          );
    });
  }

  Future<void> _removeMissingSnapshotRows(
    String entityType,
    Set<String> ids,
  ) async {
    // Table names come only from this closed mapping, never from server input.
    final TableInfo<Table, Object?> table = switch (entityType) {
      'project' => database.projects,
      'project_milestone' => database.projectMilestones,
      'task' => database.tasks,
      'calendar_event' => database.calendarEvents,
      _ => throw FormatException('unknown snapshot entity: $entityType'),
    };
    final rows = await database
        .customSelect(
          'SELECT id, sync_status, remote_version FROM ${table.actualTableName} WHERE deleted_at IS NULL',
          readsFrom: {table},
        )
        .get();
    for (final row in rows) {
      final id = row.read<String>('id');
      if (ids.contains(id)) continue;
      if (row.read<String>('sync_status') != 'synced') {
        if (row.read<int>('remote_version') > 0) {
          throw const _RemoteMutationConflict();
        }
        continue;
      }
      await database.customUpdate(
        'UPDATE ${table.actualTableName} SET deleted_at = ? WHERE id = ?',
        variables: [
          Variable<String>(DateTime.now().toUtc().toIso8601String()),
          Variable<String>(id),
        ],
        updates: {table},
      );
    }
  }

  /// A page is one transaction. Unsupported or malformed events roll back both
  /// entity changes and cursor, so retry cannot permanently skip any event.
  Future<void> applySyncEvents(Map<String, dynamic> response) async {
    final events = response['events'] as List<dynamic>;
    final next = _nonNegativeInt(response['nextCursor'], 'next cursor');
    await database.transaction(() async {
      final cursor = await _readCursor();
      var last = -1;
      for (final raw in events) {
        final event = Map<String, dynamic>.from(raw as Map);
        final eventCursor = _nonNegativeInt(event['cursor'], 'event cursor');
        if (eventCursor <= last || eventCursor > next) {
          throw const FormatException('invalid event cursor order');
        }
        last = eventCursor;
        if (eventCursor <= cursor) continue;
        await _applyRemoteEvent(event);
      }
      if ((events.isEmpty && next != cursor) ||
          (events.isNotEmpty && last != next)) {
        throw const FormatException(
          'cursor does not match complete event page',
        );
      }
      if (next > cursor) await _writeCursor(next);
    });
  }

  int _nonNegativeInt(Object? value, String field) {
    if (value is! int || value < 0) throw FormatException('invalid $field');
    return value;
  }

  Future<void> _applyRemoteEvent(Map<String, dynamic> event) async {
    final entityType = event['entityType'];
    if (!const {
      'task',
      'calendar_event',
      'project',
      'project_milestone',
    }.contains(entityType)) {
      throw FormatException('unsupported sync entity: $entityType');
    }
    final entityId = event['entityId'] as String;
    final entityVersion = _nonNegativeInt(
      event['entityVersion'],
      'entity version',
    );
    final operation = event['operation'];
    final payload = event['payloadJson'] as String?;
    if (entityId.isEmpty ||
        entityVersion == 0 ||
        (operation != 'upsert' && operation != 'delete') ||
        event['tombstone'] != (operation == 'delete')) {
      throw const FormatException('invalid sync event');
    }
    if (operation == 'upsert') {
      final value = jsonDecode(payload!) as Map<String, dynamic>;
      if (value['id'] != entityId || value['version'] != entityVersion) {
        throw const FormatException('sync payload identity/version mismatch');
      }
    } else if (event['createdAt'] is! String || payload != null) {
      throw const FormatException('invalid tombstone');
    }
    if (entityType == 'project' || entityType == 'project_milestone') {
      await _applyProjectEvent(event);
      return;
    }
    if (entityType == 'task' || entityType == 'calendar_event') {
      await _applyTaskScheduleEvent(
        event,
        entityType as String,
        entityId,
        entityVersion,
        operation as String,
        payload,
      );
    }
  }

  /// A missing conversation is an expected outcome for stale local history.
  /// Other HTTP failures remain fatal so authentication and connectivity are
  /// still surfaced by the outer sync state handling.

  /// A 409 from createMessage is only an idempotent replay when the remote
  /// conversation actually contains this message id.

  bool _isRetryableTransportError(DioException error) {
    if (error.response == null) return true;
    final status = error.response?.statusCode ?? 0;
    return status >= 500 || status == 408 || status == 429;
  }

  /// Remote state must never replace a local mutation that is still queued.
  /// The version check also makes retries and duplicated event pages harmless.
  bool shouldApplyRemote(
    String? localSyncStatus,
    int? localRemoteVersion,
    int remoteVersion,
  ) {
    if (localSyncStatus != null && localSyncStatus != 'synced') return false;
    if (localRemoteVersion != null && localRemoteVersion >= remoteVersion) {
      return false;
    }
    return true;
  }

  Future<int> _readCursor() async {
    final row = await (database.select(
      database.syncMetadata,
    )..where((item) => item.key.equals('serverCursor'))).getSingleOrNull();
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  /// A mutation key belongs to the local entity version, not to one sync run.
  /// This lets a timeout retry the same logical write without creating a new
  /// server mutation. Repository edits increment `version`, so a later edit
  /// gets a new key even when the entity id is unchanged.
  String mutationIdFor(
    String entityType,
    String entityId,
    int version,
    String operation,
  ) => 'mobile:$entityType:$entityId:$version:$operation';

  Future<void> _writeCursor(int value) async {
    await database
        .into(database.syncMetadata)
        .insertOnConflictUpdate(
          SyncMetadataCompanion.insert(key: 'serverCursor', value: '$value'),
        );
  }
}

class _RemoteMutationConflict implements Exception {
  const _RemoteMutationConflict();
}
