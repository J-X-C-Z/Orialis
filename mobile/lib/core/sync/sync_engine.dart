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

enum SyncState { idle, syncing, offline, authRequired, conflict, error }

extension SyncStatePresentation on SyncState {
  String get label => switch (this) {
    SyncState.idle => '已同步',
    SyncState.syncing => '同步中',
    SyncState.offline => '等待联网',
    SyncState.authRequired => '需要登录',
    SyncState.conflict => '需要处理',
    SyncState.error => '同步失败',
  };

  String get message => switch (this) {
    SyncState.idle => '本地内容已与服务器保持一致。',
    SyncState.syncing => '正在上传本地修改并获取最新内容。',
    SyncState.offline => '当前无法连接服务器，本地修改会继续保留。',
    SyncState.authRequired => '登录状态已失效，请重新登录后再同步；本地修改仍然保留。',
    SyncState.conflict => '发现版本冲突，本地修改已保留，不会被静默覆盖。',
    SyncState.error => '同步没有完成，请稍后重试；本地修改仍然保留。',
  };
}

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

  Future<void> _pushTasks(
    OrialisApiClient api, {
    bool includeDerivedCompletionMutations = false,
  }) async {
    final pending = await (database.select(
      database.tasks,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = _outboxStore;
    // The contract allows one child level. Upload roots first so a newly
    // created parent exists before the server validates its child's FK.
    pending.sort((left, right) {
      if (left.parentTaskId == null && right.parentTaskId != null) return -1;
      if (left.parentTaskId != null && right.parentTaskId == null) return 1;
      return 0;
    });
    await _requireTaskCapabilities(pending, outbox);
    for (final task in pending) {
      final current = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).getSingleOrNull();
      if (current == null || current.syncStatus == 'synced') continue;
      if (await _hasDeletingAssociation(current)) continue;
      final currentMutation = await outbox.findPendingForEntity(
        'task',
        current.id,
      );
      final currentPayload = currentMutation == null
          ? _taskPayload(current)
          : Map<String, dynamic>.from(
              jsonDecode(currentMutation.payloadJson) as Map,
            );
      final isDerivedCompletion =
          currentPayload['_derivedCompletionCauseId'] is String;
      // The parent mutation is authoritative for derived child completion.
      // Pull its versioned child events before sending unrelated child edits.
      if (isDerivedCompletion &&
          current.syncStatus != 'pendingCreate' &&
          !includeDerivedCompletionMutations) {
        continue;
      }
      final mutation =
          currentMutation ??
          await outbox.enqueue(
            entityType: 'task',
            entityId: current.id,
            operation: _operationFor(current.syncStatus),
            payloadJson: jsonEncode(_taskPayload(current)),
            baseVersion:
                current.syncStatus == 'pendingUpdate' ||
                    current.syncStatus == 'pendingDelete'
                ? current.remoteVersion
                : null,
            entityRevision: current.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      final payload = Map<String, dynamic>.from(
        jsonDecode(mutation.payloadJson) as Map,
      );
      // Outbox rows created by older app versions do not contain these keys.
      // Fill only absent keys so an explicit null remains an intentional clear.
      _completePendingAssociationPayload(payload, current);
      final outgoingPayload = _taskPayloadForUpload(
        payload,
        mutation.operation,
      );
      Map<String, dynamic> result;
      try {
        if (mutation.operation == 'create') {
          result = await api.createTask(outgoingPayload, mutation.mutationId);
        } else if (mutation.operation == 'delete') {
          try {
            await api.deleteTask(
              current.id,
              mutation.baseVersion,
              mutation.mutationId,
            );
          } on DioException catch (error) {
            if (error.response?.statusCode != 404) rethrow;
          }
          result = <String, dynamic>{};
        } else {
          result = await api.updateTask(current.id, {
            ...outgoingPayload,
            'baseVersion': mutation.baseVersion,
          }, mutation.mutationId);
        }
      } on DioException catch (error) {
        if (error.response?.statusCode == 409) {
          final applied = await api.findAppliedMutation(mutation.mutationId);
          if (applied == null) {
            await outbox.markConflict(mutation.mutationId, error);
            rethrow;
          }
          result = <String, dynamic>{
            'version':
                applied['entityVersion'] ??
                applied['entity_version'] ??
                current.remoteVersion,
          };
        } else {
          if (_isRetryableTransportError(error)) {
            await outbox.markRetryable(mutation.mutationId, error);
          } else {
            await outbox.markFailed(mutation.mutationId, error);
          }
          rethrow;
        }
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ?? current.remoteVersion;
      await outbox.acknowledgeTaskMutation(
        mutationId: mutation.mutationId,
        entityId: current.id,
        entityRevision: mutation.entityRevision,
        remoteVersion: remoteVersion,
        serverVersion: (result['version'] as num?)?.toInt(),
      );
      await outbox.rebasePendingForEntity(
        entityType: 'task',
        entityId: current.id,
        baseVersion: remoteVersion,
      );
      if (mutation.operation == 'delete') {
        await _cascadeLocalChildren(
          parentId: current.id,
          deletedAt:
              current.deletedAt ?? DateTime.now().toUtc().toIso8601String(),
        );
      }
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
    if (operation == 'delete' && entityType == 'task') {
      final existing = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(entityId))).getSingleOrNull();
      if (!shouldApplyRemote(
        existing?.syncStatus,
        existing?.remoteVersion,
        entityVersion,
      )) {
        return;
      }
      await _cascadeLocalChildren(
        parentId: entityId,
        deletedAt: event['createdAt'] as String,
      );
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(entityId))).write(
        TasksCompanion(
          deletedAt: Value(event['createdAt'] as String),
          updatedAt: Value(event['createdAt'] as String),
          version: Value(entityVersion),
          remoteVersion: Value(entityVersion),
          syncStatus: const Value('synced'),
        ),
      );
    } else if (operation == 'delete' && entityType == 'calendar_event') {
      final existing = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(entityId))).getSingleOrNull();
      if (!shouldApplyRemote(
        existing?.syncStatus,
        existing?.remoteVersion,
        entityVersion,
      )) {
        return;
      }
      await _cascadeLocalChildren(
        scheduleId: entityId,
        deletedAt: event['createdAt'] as String,
      );
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(entityId))).write(
        CalendarEventsCompanion(
          deletedAt: Value(event['createdAt'] as String),
          updatedAt: Value(event['createdAt'] as String),
          version: Value(entityVersion),
          remoteVersion: Value(entityVersion),
          syncStatus: const Value('synced'),
        ),
      );
    } else if (entityType == 'task' &&
        operation == 'upsert' &&
        payload != null) {
      final value = jsonDecode(payload) as Map<String, dynamic>;
      final id = value['id'] as String;
      final existing = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (!shouldApplyRemote(
        existing?.syncStatus,
        existing?.remoteVersion,
        entityVersion,
      )) {
        if (existing != null &&
            await _reconcileDerivedCompletionEvent(
              id,
              entityVersion,
              value,
              existing,
            )) {
          return;
        }
        return;
      }
      await database
          .into(database.tasks)
          .insertOnConflictUpdate(
            TasksCompanion.insert(
              manualPosition: Value((value['manualPosition'] as num?)?.toInt()),
              id: id,
              title: value['title'] as String,
              notes: Value(value['notes'] as String?),
              due: Value(value['due'] as String?),
              dueTime: Value(value['dueTime'] as String?),
              completedAt: Value(value['completedAt'] as String?),
              reminderMinutes: Value(
                (value['reminderMinutes'] as num?)?.toInt(),
              ),
              projectId: Value(value['projectId'] as String?),
              parentTaskId: Value(
                _optionalAssociation(
                  value,
                  'parent_task_id',
                  'parentTaskId',
                  existing?.parentTaskId,
                ),
              ),
              scheduleId: Value(
                _optionalAssociation(
                  value,
                  'schedule_id',
                  'scheduleId',
                  existing?.scheduleId,
                ),
              ),
              recurrence: Value(_recurrenceJson(value['recurrence'])),
              important: Value(value['important'] as bool?),
              urgent: Value(value['urgent'] as bool?),
              completed: Value(value['completed'] as bool? ?? false),
              version: Value((value['version'] as num?)?.toInt() ?? 1),
              remoteVersion: Value((value['version'] as num?)?.toInt() ?? 1),
              deletedAt: Value(value['deletedAt'] as String?),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              syncStatus: const Value('synced'),
            ),
          );
    } else if (entityType == 'calendar_event' &&
        operation == 'upsert' &&
        payload != null) {
      final value = jsonDecode(payload) as Map<String, dynamic>;
      final id = value['id'] as String;
      final existing = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (!shouldApplyRemote(
        existing?.syncStatus,
        existing?.remoteVersion,
        entityVersion,
      )) {
        return;
      }
      await database
          .into(database.calendarEvents)
          .insertOnConflictUpdate(
            CalendarEventsCompanion.insert(
              id: id,
              title: value['title'] as String,
              description: Value(value['description'] as String?),
              location: Value(value['location'] as String?),
              startAt: value['startAt'] as String,
              endAt: value['endAt'] as String,
              allDay: Value(value['allDay'] as bool? ?? false),
              important: Value(
                value['important'] as bool? ?? existing?.important ?? false,
              ),
              reminderMinutes: Value(
                (value['reminderMinutes'] as num?)?.toInt(),
              ),
              version: Value((value['version'] as num?)?.toInt() ?? 1),
              remoteVersion: Value((value['version'] as num?)?.toInt() ?? 1),
              deletedAt: Value(value['deletedAt'] as String?),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              syncStatus: const Value('synced'),
            ),
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

  Future<void> _requireTaskCapabilities(
    List<Task> tasks,
    OutboxStore outbox,
  ) async {
    final required = <String>{};
    for (final task in tasks) {
      if (_operationFor(task.syncStatus) == 'delete') continue;
      final mutation = await outbox.findPendingForEntity('task', task.id);
      final payload = mutation == null
          ? _taskPayload(task)
          : Map<String, dynamic>.from(jsonDecode(mutation.payloadJson) as Map);
      if (task.parentTaskId != null ||
          task.scheduleId != null ||
          _associationFrom(payload, 'parentTaskId', 'parent_task_id') != null ||
          _associationFrom(payload, 'scheduleId', 'schedule_id') != null ||
          payload['_requiresTaskChildren'] == true) {
        required.add('task_children');
      }
    }
    await _requireCapabilities(required);
  }

  Future<void> _requireScheduleCapabilities(
    List<CalendarEvent> schedules,
    OutboxStore outbox,
  ) async {
    final required = <String>{};
    for (final schedule in schedules) {
      if (_operationFor(schedule.syncStatus) == 'delete') continue;
      final mutation = await outbox.findPendingForEntity(
        'schedule',
        schedule.id,
      );
      final payload = mutation == null
          ? _schedulePayload(schedule)
          : Map<String, dynamic>.from(jsonDecode(mutation.payloadJson) as Map);
      if (schedule.important ||
          payload['important'] == true ||
          payload['_requiresScheduleImportance'] == true) {
        required.add('schedule_importance');
      }
    }
    await _requireCapabilities(required);
  }

  Future<void> _requireCapabilities(Set<String> required) async {
    if (required.isEmpty) return;
    var capabilities = _serverCapabilities;
    if (capabilities == null) {
      capabilities = await (await _resolveApi()).capabilities();
      _serverCapabilities = capabilities;
    }
    final missing = required
        .where((item) => !capabilities!.contains(item))
        .toSet();
    if (missing.isNotEmpty) {
      throw StateError(
        'server does not support required capability: ${missing.join(', ')}',
      );
    }
  }

  String? _associationFrom(
    Map<String, dynamic> value,
    String camelKey,
    String snakeKey,
  ) => value[camelKey] as String? ?? value[snakeKey] as String?;

  Future<void> _pushCalendarEvents(OrialisApiClient api) async {
    final pending = await (database.select(
      database.calendarEvents,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = _outboxStore;
    await _requireScheduleCapabilities(pending, outbox);
    for (final event in pending) {
      final current = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(event.id))).getSingleOrNull();
      if (current == null || current.syncStatus == 'synced') continue;
      final mutation =
          await outbox.findPendingForEntity('schedule', current.id) ??
          await outbox.enqueue(
            entityType: 'schedule',
            entityId: current.id,
            operation: _operationFor(current.syncStatus),
            payloadJson: jsonEncode(_schedulePayload(current)),
            baseVersion:
                current.syncStatus == 'pendingUpdate' ||
                    current.syncStatus == 'pendingDelete'
                ? current.remoteVersion
                : null,
            entityRevision: current.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      final payload = Map<String, dynamic>.from(
        jsonDecode(mutation.payloadJson) as Map,
      );
      final outgoingPayload = Map<String, dynamic>.from(payload)
        ..remove('_requiresScheduleImportance');
      Map<String, dynamic> result;
      try {
        if (mutation.operation == 'create') {
          result = await api.createSchedule(
            outgoingPayload,
            mutation.mutationId,
          );
        } else if (mutation.operation == 'delete') {
          try {
            await api.deleteSchedule(
              current.id,
              mutation.baseVersion,
              mutation.mutationId,
            );
          } on DioException catch (error) {
            if (error.response?.statusCode != 404) rethrow;
          }
          await _cascadeLocalChildren(
            scheduleId: current.id,
            deletedAt:
                current.deletedAt ?? DateTime.now().toUtc().toIso8601String(),
          );
          result = <String, dynamic>{};
        } else {
          result = await api.updateSchedule(current.id, {
            ...outgoingPayload,
            'baseVersion': mutation.baseVersion,
          }, mutation.mutationId);
        }
      } on DioException catch (error) {
        if (error.response?.statusCode == 409) {
          final applied = await api.findAppliedMutation(mutation.mutationId);
          if (applied == null) {
            await outbox.markConflict(mutation.mutationId, error);
            rethrow;
          }
          result = <String, dynamic>{
            'version':
                applied['entityVersion'] ??
                applied['entity_version'] ??
                current.remoteVersion,
          };
        } else {
          if (_isRetryableTransportError(error)) {
            await outbox.markRetryable(mutation.mutationId, error);
          } else {
            await outbox.markFailed(mutation.mutationId, error);
          }
          rethrow;
        }
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ?? current.remoteVersion;
      await outbox.acknowledgeScheduleMutation(
        mutationId: mutation.mutationId,
        entityId: current.id,
        entityRevision: mutation.entityRevision,
        remoteVersion: remoteVersion,
        serverVersion: (result['version'] as num?)?.toInt(),
      );
      await outbox.rebasePendingForEntity(
        entityType: 'schedule',
        entityId: current.id,
        baseVersion: remoteVersion,
      );
    }
  }

  String _operationFor(String status) => switch (status) {
    'pendingCreate' => 'create',
    'pendingDelete' => 'delete',
    _ => 'update',
  };

  Map<String, dynamic> _taskPayload(Task task) => {
    'id': task.id,
    'title': task.title,
    'notes': task.notes,
    'important': task.important,
    'urgent': task.urgent,
    'completed': task.completed,
    'completedAt': task.completedAt,
    'due': task.due,
    'dueTime': task.dueTime,
    'reminderMinutes': task.reminderMinutes,
    'projectId': task.projectId,
    'parentTaskId': task.parentTaskId,
    'manualPosition': task.manualPosition,
    'scheduleId': task.scheduleId,
    'recurrence': task.recurrence == null ? null : jsonDecode(task.recurrence!),
    'createdAt': task.createdAt,
    'updatedAt': task.updatedAt,
    'deletedAt': task.deletedAt,
    'version': task.version,
  };

  Map<String, dynamic> _schedulePayload(CalendarEvent event) => {
    'id': event.id,
    'title': event.title,
    'description': event.description,
    'location': event.location,
    'startAt': event.startAt,
    'endAt': event.endAt,
    'allDay': event.allDay,
    'important': event.important,
    'reminderMinutes': event.reminderMinutes,
    'createdAt': event.createdAt,
    'updatedAt': event.updatedAt,
    'deletedAt': event.deletedAt,
    'version': event.version,
  };

  Future<bool> _hasDeletingAssociation(Task task) async {
    if (task.parentTaskId != null) {
      final parent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.parentTaskId!))).getSingleOrNull();
      if (parent != null &&
          (parent.syncStatus == 'pendingDelete' || parent.deletedAt != null)) {
        return true;
      }
    }
    if (task.scheduleId != null) {
      final schedule = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(task.scheduleId!))).getSingleOrNull();
      if (schedule != null &&
          (schedule.syncStatus == 'pendingDelete' ||
              schedule.deletedAt != null)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _cascadeLocalChildren({
    String? parentId,
    String? scheduleId,
    required String deletedAt,
  }) async {
    final children =
        await (database.select(database.tasks)..where(
              (row) => parentId != null
                  ? row.parentTaskId.equals(parentId)
                  : row.scheduleId.equals(scheduleId!),
            ))
            .get();
    for (final child in children) {
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).write(
        TasksCompanion(
          deletedAt: Value(deletedAt),
          updatedAt: Value(deletedAt),
          syncStatus: const Value('synced'),
        ),
      );
      await (database.update(database.outboxMutations)..where(
            (row) =>
                row.entityType.equals('task') &
                row.entityId.equals(child.id) &
                row.status.isNotIn(const ['acknowledged']),
          ))
          .write(
            OutboxMutationsCompanion(
              status: const Value(OutboxStatus.acknowledged),
              lastError: const Value(null),
              updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
            ),
          );
    }
  }

  void _completePendingAssociationPayload(
    Map<String, dynamic> payload,
    Task task,
  ) {
    _copyAssociationAlias(payload, 'parentTaskId', 'parent_task_id');
    _copyAssociationAlias(payload, 'scheduleId', 'schedule_id');
    payload.putIfAbsent('parentTaskId', () => task.parentTaskId);
    payload.putIfAbsent('scheduleId', () => task.scheduleId);
  }

  Map<String, dynamic> _taskPayloadForUpload(
    Map<String, dynamic> payload,
    String operation,
  ) {
    final result = Map<String, dynamic>.from(payload)
      ..remove('_requiresTaskChildren');
    final derivedCompletion = result.remove('_derivedCompletionCauseId');
    if (operation == 'update' && derivedCompletion is String) {
      result.remove('completed');
      result.remove('completedAt');
    }
    return result;
  }

  Future<bool> _reconcileDerivedCompletionEvent(
    String taskId,
    int remoteVersion,
    Map<String, dynamic> remote,
    Task local,
  ) async {
    final mutation = await _outboxStore.findPendingForEntity('task', taskId);
    if (mutation == null) return false;
    final payload = Map<String, dynamic>.from(
      jsonDecode(mutation.payloadJson) as Map,
    );
    final causeId = payload['_derivedCompletionCauseId'];
    final remoteParentId = _optionalAssociation(
      remote,
      'parentTaskId',
      'parent_task_id',
      local.parentTaskId,
    );
    final desiredCompleted = payload['completed'];
    var causalityConfirmed = false;
    if (causeId is String &&
        causeId == local.parentTaskId &&
        causeId == remoteParentId) {
      causalityConfirmed = true;
    } else if (causeId is String &&
        local.parentTaskId == null &&
        causeId != local.id &&
        desiredCompleted is bool &&
        desiredCompleted == remote['completed']) {
      final causeTask = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(causeId))).getSingleOrNull();
      causalityConfirmed =
          causeTask?.parentTaskId == local.id &&
          causeTask?.completed == desiredCompleted;
    }
    if (!causalityConfirmed ||
        desiredCompleted is! bool ||
        remote['completed'] != desiredCompleted) {
      return false;
    }

    // The event confirms only the derived completion. Preserve every other
    // local edit and advance the queued write to the server's new version.
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(taskId))).write(
      TasksCompanion(
        completed: Value(desiredCompleted),
        completedAt: Value(remote['completedAt'] as String?),
        updatedAt: Value(remote['updatedAt'] as String? ?? local.updatedAt),
        version: Value(remoteVersion),
        remoteVersion: Value(remoteVersion),
      ),
    );
    await _outboxStore.rebasePendingForEntity(
      entityType: 'task',
      entityId: taskId,
      baseVersion: remoteVersion,
    );
    return true;
  }

  void _copyAssociationAlias(
    Map<String, dynamic> payload,
    String wireKey,
    String legacyKey,
  ) {
    if (!payload.containsKey(wireKey) && payload.containsKey(legacyKey)) {
      payload[wireKey] = payload[legacyKey];
    }
    payload.remove(legacyKey);
  }

  String? _optionalAssociation(
    Map<String, dynamic> value,
    String wireKey,
    String legacyKey,
    String? previous,
  ) {
    if (value.containsKey(legacyKey)) return value[legacyKey] as String?;
    if (value.containsKey(wireKey)) return value[wireKey] as String?;
    return previous;
  }

  String? _recurrenceJson(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value['rule'] is! String ||
        value['until'] is! String) {
      throw const FormatException('invalid recurrence payload');
    }
    return jsonEncode({'rule': value['rule'], 'until': value['until']});
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
