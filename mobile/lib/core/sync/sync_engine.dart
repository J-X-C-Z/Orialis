import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../config/app_config.dart';
import '../attachments/attachment_bridge.dart';
import '../database/app_database.dart';
import '../network/orialis_api_client.dart';
import 'outbox_store.dart';

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
  SyncEngine({required this.database, required this.config, this.apiClient});

  final AppDatabase database;
  final AppConfig config;
  final OrialisApiClient? apiClient;

  Future<SyncState> syncOnce() async {
    final baseUrl = await config.serverUrl();
    final deviceId = await config.deviceId();
    final api =
        apiClient ??
        OrialisApiClient(baseUrl: baseUrl, deviceId: deviceId, config: config);
    final outbox = OutboxStore(database);
    try {
      await outbox.recoverInFlight();
      await outbox.recoverAcknowledgedEntities();
      await _pushConversations(api);
      await _pushTasks(api);
      await _pushCalendarEvents(api);
      await _pullConversations(api);
      await _pushMessages(api);
      await _pullMessages(api);
      await _pull(api);
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

  Future<void> _pushConversations(OrialisApiClient api) async {
    final pending = await (database.select(
      database.conversations,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    for (final conversation in pending) {
      final mutationId = mutationIdFor(
        'conversation',
        conversation.id,
        conversation.localRevision,
        conversation.syncStatus,
      );
      Map<String, dynamic> result;
      if (conversation.syncStatus == 'pendingCreate') {
        result = await api.createConversation(
          id: conversation.id,
          title: conversation.title,
          mutationId: mutationId,
        );
      } else if (conversation.syncStatus == 'pendingDelete') {
        try {
          await api.deleteConversation(
            conversation.id,
            conversation.remoteVersion,
            mutationId,
          );
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
        }
        result = <String, dynamic>{};
      } else {
        result = await api.renameConversation(
          conversation.id,
          conversation.title,
          conversation.remoteVersion,
          mutationId,
        );
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ??
          conversation.remoteVersion +
              (conversation.syncStatus == 'pendingDelete' ? 1 : 0);
      final current = await (database.select(
        database.conversations,
      )..where((row) => row.id.equals(conversation.id))).getSingle();
      await (database.update(
        database.conversations,
      )..where((row) => row.id.equals(conversation.id))).write(
        ConversationsCompanion(
          version: Value(remoteVersion),
          remoteVersion: Value(remoteVersion),
          syncStatus: Value(
            current.localRevision == conversation.localRevision
                ? 'synced'
                : current.syncStatus == 'pendingCreate'
                ? 'pendingUpdate'
                : current.syncStatus,
          ),
        ),
      );
    }
  }

  Future<void> _pullConversations(OrialisApiClient api) async {
    final remote = await api.listConversations();
    for (final value in remote) {
      final id = value['id'] as String?;
      final title = value['title'] as String?;
      final createdAt = value['createdAt'] as String?;
      final updatedAt = value['updatedAt'] as String?;
      if (id == null ||
          title == null ||
          createdAt == null ||
          updatedAt == null) {
        continue;
      }
      final remoteVersion = (value['version'] as num?)?.toInt() ?? 1;
      final existing = await (database.select(
        database.conversations,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (!shouldApplyRemote(
        existing?.syncStatus,
        existing?.remoteVersion,
        remoteVersion,
      )) {
        continue;
      }
      final type =
          value['type'] as String? ??
          ((value['isDefault'] as bool? ?? false) ? 'main' : 'normal');
      await database
          .into(database.conversations)
          .insertOnConflictUpdate(
            ConversationsCompanion.insert(
              id: id,
              title: title,
              type: Value(type),
              createdAt: createdAt,
              updatedAt: updatedAt,
              version: Value(remoteVersion),
              remoteVersion: Value(remoteVersion),
              syncStatus: const Value('synced'),
            ),
          );
    }
  }

  Future<void> _pushTasks(OrialisApiClient api) async {
    final pending = await (database.select(
      database.tasks,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = OutboxStore(database);
    for (final task in pending) {
      final mutation =
          await outbox.findPendingForEntity('task', task.id) ??
          await outbox.enqueue(
            entityType: 'task',
            entityId: task.id,
            operation: _operationFor(task.syncStatus),
            payloadJson: jsonEncode(_taskPayload(task)),
            baseVersion:
                task.syncStatus == 'pendingUpdate' ||
                    task.syncStatus == 'pendingDelete'
                ? task.remoteVersion
                : null,
            entityRevision: task.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      final payload = jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
      Map<String, dynamic> result;
      try {
        if (mutation.operation == 'create') {
          result = await api.createTask(payload, mutation.mutationId);
        } else if (mutation.operation == 'delete') {
          try {
            await api.deleteTask(
              task.id,
              mutation.baseVersion,
              mutation.mutationId,
            );
          } on DioException catch (error) {
            if (error.response?.statusCode != 404) rethrow;
          }
          result = <String, dynamic>{};
        } else {
          result = await api.updateTask(task.id, {
            ...payload,
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
                task.remoteVersion,
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
          (result['version'] as num?)?.toInt() ?? task.remoteVersion;
      await outbox.acknowledgeTaskMutation(
        mutationId: mutation.mutationId,
        entityId: task.id,
        entityRevision: mutation.entityRevision,
        remoteVersion: remoteVersion,
        serverVersion: (result['version'] as num?)?.toInt(),
      );
      await outbox.rebasePendingForEntity(
        entityType: 'task',
        entityId: task.id,
        baseVersion: remoteVersion,
      );
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
        return;
      }
      await database
          .into(database.tasks)
          .insertOnConflictUpdate(
            TasksCompanion.insert(
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

  Future<void> _applyProjectEvent(Map<String, dynamic> event) async {
    final isProject = event['entityType'] == 'project';
    final TableInfo<Table, Object?> table = isProject
        ? database.projects
        : database.projectMilestones;
    final id = event['entityId'] as String;
    final version = event['entityVersion'] as int;
    final existing = await database
        .customSelect(
          'SELECT remote_version, sync_status FROM ${table.actualTableName} WHERE id = ?',
          variables: [Variable<String>(id)],
          readsFrom: {table},
        )
        .getSingleOrNull();
    // A tombstone can arrive before this client ever saw the entity. Its payload
    // has no name/title/projectId, so retain its version separately instead of
    // inventing a partial domain row that could later be resurrected by replay.
    final tombstoneKey = 'remoteTombstone:${event['entityType']}:$id';
    final tombstone = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.equals(tombstoneKey))).getSingleOrNull();
    final deletedVersion = int.tryParse(tombstone?.value ?? '') ?? 0;
    if (version <= deletedVersion ||
        version <= (existing?.read<int>('remote_version') ?? 0)) {
      return;
    }
    if (existing != null && existing.read<String>('sync_status') != 'synced') {
      throw const _RemoteMutationConflict();
    }
    if (event['operation'] == 'delete') {
      final deletedAt = event['createdAt'] as String;
      await database.customUpdate(
        'UPDATE ${table.actualTableName} SET deleted_at = ?, updated_at = ?, '
        'version = ?, remote_version = ?, sync_status = ? WHERE id = ?',
        variables: [
          Variable<String>(deletedAt),
          Variable<String>(deletedAt),
          Variable<int>(version),
          Variable<int>(version),
          const Variable<String>('synced'),
          Variable<String>(id),
        ],
        updates: {table},
      );
      await database
          .into(database.syncMetadata)
          .insertOnConflictUpdate(
            SyncMetadataCompanion.insert(key: tombstoneKey, value: '$version'),
          );
      return;
    }
    final value =
        jsonDecode(event['payloadJson'] as String) as Map<String, dynamic>;
    if (isProject) {
      final status = value['status'] as String;
      if (!const {'active', 'completed', 'archived'}.contains(status)) {
        throw const FormatException('invalid project status');
      }
      await database
          .into(database.projects)
          .insertOnConflictUpdate(
            ProjectsCompanion.insert(
              id: id,
              name: value['name'] as String,
              goal: Value(value['goal'] as String?),
              description: Value(value['description'] as String?),
              color: Value(value['color'] as String?),
              status: Value(status),
              startDate: Value(value['startDate'] as String?),
              due: Value(value['due'] as String?),
              nextActionTaskId: Value(value['nextActionTaskId'] as String?),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              version: Value(version),
              remoteVersion: Value(version),
              deletedAt: const Value(null),
              syncStatus: const Value('synced'),
            ),
          );
    } else {
      final projectId = value['projectId'] as String;
      final previous = await (database.select(
        database.projectMilestones,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (previous != null && previous.projectId != projectId) {
        throw const FormatException('milestone projectId is immutable');
      }
      await database
          .into(database.projectMilestones)
          .insertOnConflictUpdate(
            ProjectMilestonesCompanion.insert(
              id: id,
              projectId: projectId,
              title: value['title'] as String,
              due: Value(value['due'] as String?),
              completed: Value(value['completed'] as bool),
              completedAt: Value(value['completedAt'] as String?),
              position: Value(
                _nonNegativeInt(value['position'], 'milestone position'),
              ),
              createdAt: value['createdAt'] as String,
              updatedAt: value['updatedAt'] as String,
              version: Value(version),
              remoteVersion: Value(version),
              deletedAt: Value(value['deletedAt'] as String?),
              syncStatus: const Value('synced'),
            ),
          );
    }
  }

  Future<void> _pushMessages(OrialisApiClient api) async {
    final pending = await (database.select(
      database.messages,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    for (final message in pending) {
      // Local conversation deletion is authoritative for queued messages.
      // Do this before attachment upload so a deleted conversation cannot
      // trigger a doomed upload/message POST and block the whole sync pass.
      final conversation =
          await (database.select(database.conversations)
                ..where((row) => row.id.equals(message.conversationId)))
              .getSingleOrNull();
      if (conversation?.deletedAt != null) {
        await _markMessageSynced(message);
        continue;
      }
      final records = AttachmentBridge.decode(message.attachmentsJson);
      final attachments = <Map<String, dynamic>>[];
      for (var index = 0; index < records.length; index++) {
        var record = records[index];
        if (!record.isUploaded) {
          final attempt = record.attempts + 1;
          record = record.copyWith(
            status: AttachmentStatus.uploading,
            attempts: attempt,
            lastAttemptAt: DateTime.now().toUtc().toIso8601String(),
            lastError: null,
          );
          records[index] = record;
          await _saveAttachmentRecords(message, records);
          try {
            final uploaded = await api.uploadAttachments(
              conversationId: message.conversationId,
              idempotencyKey: '${message.id}:attachment:$index',
              files: [
                AttachmentUpload(
                  path: record.localPath,
                  name: record.name,
                  mimeType: record.mimeType,
                ),
              ],
            );
            if (uploaded.isEmpty) {
              throw StateError('attachment upload returned no item');
            }
            final value = uploaded.single;
            record = record.copyWith(
              status: AttachmentStatus.uploaded,
              id: value['id'] as String?,
              downloadUrl: value['downloadUrl'] as String?,
              lastError: null,
            );
            records[index] = record;
            await _saveAttachmentRecords(message, records);
          } catch (error) {
            records[index] = record.copyWith(
              status: AttachmentStatus.failed,
              lastError: error.toString(),
            );
            await _saveAttachmentRecords(message, records);
            rethrow;
          }
        }
        if (record.id == null) throw StateError('attachment has no server id');
        attachments.add(
          record.toMessageJson({
            'id': record.id,
            'downloadUrl': record.downloadUrl,
          }),
        );
      }
      late final Map<String, dynamic> result;
      try {
        result = await api.createMessage(
          conversationId: message.conversationId,
          id: message.id,
          content: message.content,
          attachments: attachments,
        );
      } on DioException catch (error) {
        // The remote conversation may have been deleted independently. This
        // message can no longer be delivered; isolate it while preserving
        // normal failure handling for auth, network, and server errors.
        if (isIgnorableMessageCreateStatus(error.response?.statusCode)) {
          await _markMessageSynced(message);
          continue;
        }
        if (error.response?.statusCode == 409) {
          try {
            final remote = await api.listMessages(message.conversationId);
            if (remoteContainsMessage(remote, message.id)) {
              await _markMessageSynced(message);
              continue;
            }
          } on DioException catch (lookupError) {
            if (isIgnorableMessageFetchStatus(
              lookupError.response?.statusCode,
            )) {
              await _markMessageSynced(message);
              continue;
            }
            rethrow;
          }
        }
        rethrow;
      }
      await (database.update(database.messages)..where(
            (row) =>
                row.conversationId.equals(message.conversationId) &
                row.id.equals(message.id),
          ))
          .write(
            MessagesCompanion(
              remoteVersion: Value(
                (result['version'] as num?)?.toInt() ?? message.remoteVersion,
              ),
              syncStatus: const Value('synced'),
            ),
          );
    }
  }

  Future<void> _markMessageSynced(Message message) async {
    await (database.update(database.messages)..where(
          (row) =>
              row.conversationId.equals(message.conversationId) &
              row.id.equals(message.id),
        ))
        .write(const MessagesCompanion(syncStatus: Value('synced')));
  }

  Future<void> _saveAttachmentRecords(
    Message message,
    List<AttachmentRecord> records,
  ) async {
    await (database.update(database.messages)..where(
          (row) =>
              row.conversationId.equals(message.conversationId) &
              row.id.equals(message.id),
        ))
        .write(
          MessagesCompanion(
            attachmentsJson: Value(AttachmentBridge.encode(records)),
          ),
        );
  }

  Future<void> _pullMessages(OrialisApiClient api) async {
    final activeConversations = database.selectOnly(database.conversations)
      ..addColumns([database.conversations.id])
      ..where(database.conversations.deletedAt.isNull());
    final conversationIdsFromConversations = await activeConversations
        .map((row) => row.read(database.conversations.id)!)
        .get();
    final conversationIds = {'default', ...conversationIdsFromConversations};
    for (final conversationId in conversationIds) {
      // A locally deleted conversation may still be present in the local
      // message index while the server has already removed it. Isolate that
      // conversation: one stale 404 must not prevent other messages, tasks,
      // or calendar events from syncing.
      late final List<Map<String, dynamic>> remote;
      try {
        remote = await api.listMessages(conversationId);
      } on DioException catch (error) {
        if (isIgnorableMessageFetchStatus(error.response?.statusCode)) {
          continue;
        }
        rethrow;
      }
      for (final value in remote) {
        final remoteConversationId = value['conversationId'] as String;
        final id = value['id'] as String;
        final remoteVersion = (value['version'] as num?)?.toInt() ?? 1;
        final existing =
            await (database.select(database.messages)..where(
                  (row) =>
                      row.conversationId.equals(remoteConversationId) &
                      row.id.equals(id),
                ))
                .getSingleOrNull();
        if (!shouldApplyRemote(
          existing?.syncStatus,
          existing?.remoteVersion,
          remoteVersion,
        )) {
          continue;
        }
        await database
            .into(database.messages)
            .insertOnConflictUpdate(
              MessagesCompanion.insert(
                conversationId: remoteConversationId,
                id: id,
                role: value['role'] as String,
                content: value['content'] as String,
                createdAt: value['createdAt'] as String,
                attachmentsJson: Value(
                  jsonEncode(value['attachments'] ?? const []),
                ),
                remoteVersion: Value(remoteVersion),
                syncStatus: const Value('synced'),
              ),
            );
      }
    }
  }

  /// A missing conversation is an expected outcome for stale local history.
  /// Other HTTP failures remain fatal so authentication and connectivity are
  /// still surfaced by the outer sync state handling.
  bool isIgnorableMessageFetchStatus(int? statusCode) => statusCode == 404;

  bool isIgnorableMessageCreateStatus(int? statusCode) => statusCode == 404;

  /// A 409 from createMessage is only an idempotent replay when the remote
  /// conversation actually contains this message id.
  bool remoteContainsMessage(
    Iterable<Map<String, dynamic>> remote,
    String messageId,
  ) => remote.any((value) => value['id'] == messageId);

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

  Future<void> _pushCalendarEvents(OrialisApiClient api) async {
    final pending = await (database.select(
      database.calendarEvents,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    final outbox = OutboxStore(database);
    for (final event in pending) {
      final mutation =
          await outbox.findPendingForEntity('schedule', event.id) ??
          await outbox.enqueue(
            entityType: 'schedule',
            entityId: event.id,
            operation: _operationFor(event.syncStatus),
            payloadJson: jsonEncode(_schedulePayload(event)),
            baseVersion:
                event.syncStatus == 'pendingUpdate' ||
                    event.syncStatus == 'pendingDelete'
                ? event.remoteVersion
                : null,
            entityRevision: event.localRevision,
          );
      await outbox.markInFlight(mutation.mutationId);
      final payload = jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
      Map<String, dynamic> result;
      try {
        if (mutation.operation == 'create') {
          result = await api.createSchedule(payload, mutation.mutationId);
        } else if (mutation.operation == 'delete') {
          try {
            await api.deleteSchedule(
              event.id,
              mutation.baseVersion,
              mutation.mutationId,
            );
          } on DioException catch (error) {
            if (error.response?.statusCode != 404) rethrow;
          }
          result = <String, dynamic>{};
        } else {
          result = await api.updateSchedule(event.id, {
            ...payload,
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
                event.remoteVersion,
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
          (result['version'] as num?)?.toInt() ?? event.remoteVersion;
      await outbox.acknowledgeScheduleMutation(
        mutationId: mutation.mutationId,
        entityId: event.id,
        entityRevision: mutation.entityRevision,
        remoteVersion: remoteVersion,
        serverVersion: (result['version'] as num?)?.toInt(),
      );
      await outbox.rebasePendingForEntity(
        entityType: 'schedule',
        entityId: event.id,
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
    'reminderMinutes': event.reminderMinutes,
    'createdAt': event.createdAt,
    'updatedAt': event.updatedAt,
    'deletedAt': event.deletedAt,
    'version': event.version,
  };

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
