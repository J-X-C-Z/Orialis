import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../attachments/attachment_bridge.dart';
import '../database/app_database.dart';
import '../network/orialis_api_client.dart';

enum SyncState { idle, syncing, offline, conflict, error }

extension SyncStatePresentation on SyncState {
  String get label => switch (this) {
    SyncState.idle => '已同步',
    SyncState.syncing => '同步中',
    SyncState.offline => '等待联网',
    SyncState.conflict => '需要处理',
    SyncState.error => '同步失败',
  };

  String get message => switch (this) {
    SyncState.idle => '本地内容已与服务器保持一致。',
    SyncState.syncing => '正在上传本地修改并获取最新内容。',
    SyncState.offline => '当前无法连接服务器，本地修改会继续保留。',
    SyncState.conflict => '发现版本冲突，本地修改已保留，不会被静默覆盖。',
    SyncState.error => '同步没有完成，请稍后重试；本地修改仍然保留。',
  };
}

class SyncEngine {
  SyncEngine({required this.database, required this.config});

  final AppDatabase database;
  final AppConfig config;

  Future<SyncState> syncOnce() async {
    final baseUrl = await config.serverUrl();
    final deviceId = await config.deviceId();
    final api = OrialisApiClient(baseUrl: baseUrl, deviceId: deviceId);
    try {
      await _pushConversations(api);
      await _pushTasks(api);
      await _pushCalendarEvents(api);
      await _pullConversations(api);
      await _pushMessages(api);
      await _pullMessages(api);
      await _pull(api);
      return SyncState.idle;
    } on DioException catch (error) {
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
      final mutationId = const Uuid().v7();
      Map<String, dynamic> result;
      if (conversation.syncStatus == 'pendingCreate') {
        result = await api.createConversation(
          id: conversation.id,
          title: conversation.title,
          mutationId: mutationId,
        );
      } else if (conversation.syncStatus == 'pendingDelete') {
        try {
          await api.deleteConversation(conversation.id, mutationId);
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
        }
        result = <String, dynamic>{};
      } else {
        result = await api.renameConversation(
          conversation.id,
          conversation.title,
          mutationId,
        );
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ?? conversation.remoteVersion;
      await (database.update(
        database.conversations,
      )..where((row) => row.id.equals(conversation.id))).write(
        ConversationsCompanion(
          remoteVersion: Value(remoteVersion),
          syncStatus: const Value('synced'),
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
    for (final task in pending) {
      final mutationId = const Uuid().v7();
      final payload = <String, dynamic>{
        'id': task.id,
        'title': task.title,
        'notes': task.notes,
        'important': task.important,
        'urgent': task.urgent,
        'completed': task.completed,
        'due': task.due,
        'dueTime': task.dueTime,
        'projectId': task.projectId,
      };
      Map<String, dynamic> result;
      if (task.syncStatus == 'pendingCreate') {
        result = await api.createTask(payload, mutationId);
      } else if (task.syncStatus == 'pendingDelete') {
        try {
          await api.deleteTask(task.id, mutationId);
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
        }
        result = <String, dynamic>{};
      } else {
        result = await api.updateTask(task.id, {
          ...payload,
          'baseVersion': task.remoteVersion,
        }, mutationId);
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ?? task.remoteVersion;
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).write(
        TasksCompanion(
          remoteVersion: Value(remoteVersion),
          syncStatus: const Value('synced'),
        ),
      );
    }
  }

  Future<void> _pull(OrialisApiClient api) async {
    final cursor = await _readCursor();
    final response = await api.syncEvents(after: cursor);
    final events = (response['events'] as List<dynamic>? ?? const []);
    for (final raw in events) {
      final event = Map<String, dynamic>.from(raw as Map);
      final payload = event['payloadJson'] as String?;
      final entityType = event['entityType'];
      final operation = event['operation'];
      final entityId = event['entityId'] as String?;
      final entityVersion = (event['entityVersion'] as num?)?.toInt() ?? 1;
      if (operation == 'delete' && entityId != null && entityType == 'task') {
        final existing = await (database.select(
          database.tasks,
        )..where((row) => row.id.equals(entityId))).getSingleOrNull();
        if (!shouldApplyRemote(
          existing?.syncStatus,
          existing?.remoteVersion,
          entityVersion,
        )) {
          continue;
        }
        await (database.update(
          database.tasks,
        )..where((row) => row.id.equals(entityId))).write(
          TasksCompanion(
            deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
            version: Value(entityVersion),
            remoteVersion: Value(entityVersion),
            syncStatus: const Value('synced'),
          ),
        );
      } else if (operation == 'delete' &&
          entityId != null &&
          entityType == 'calendar_event') {
        final existing = await (database.select(
          database.calendarEvents,
        )..where((row) => row.id.equals(entityId))).getSingleOrNull();
        if (!shouldApplyRemote(
          existing?.syncStatus,
          existing?.remoteVersion,
          entityVersion,
        )) {
          continue;
        }
        await (database.update(
          database.calendarEvents,
        )..where((row) => row.id.equals(entityId))).write(
          CalendarEventsCompanion(
            deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
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
          continue;
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
                projectId: Value(value['projectId'] as String?),
                important: Value(value['important'] as bool? ?? false),
                urgent: Value(value['urgent'] as bool? ?? false),
                completed: Value(value['completed'] as bool? ?? false),
                version: Value((value['version'] as num?)?.toInt() ?? 1),
                remoteVersion: Value((value['version'] as num?)?.toInt() ?? 1),
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
          continue;
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
                version: Value((value['version'] as num?)?.toInt() ?? 1),
                remoteVersion: Value((value['version'] as num?)?.toInt() ?? 1),
                createdAt: value['createdAt'] as String,
                updatedAt: value['updatedAt'] as String,
                syncStatus: const Value('synced'),
              ),
            );
      }
    }
    final next = (response['nextCursor'] as num?)?.toInt() ?? cursor;
    await _writeCursor(next);
  }

  Future<void> _pushMessages(OrialisApiClient api) async {
    final pending = await (database.select(
      database.messages,
    )..where((row) => row.syncStatus.isNotIn(const ['synced']))).get();
    for (final message in pending) {
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
      final result = await api.createMessage(
        conversationId: message.conversationId,
        id: message.id,
        content: message.content,
        attachments: attachments,
      );
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
    final conversationIdsFromConversations =
        await (database.selectOnly(database.conversations)
              ..addColumns([database.conversations.id]))
            .map((row) => row.read(database.conversations.id)!)
            .get();
    final conversationIdsFromMessages =
        await (database.selectOnly(database.messages)
              ..addColumns([database.messages.conversationId])
              ..groupBy([database.messages.conversationId]))
            .map((row) => row.read(database.messages.conversationId)!)
            .get();
    final conversationIds = {
      'default',
      ...conversationIdsFromConversations,
      ...conversationIdsFromMessages,
    };
    for (final conversationId in conversationIds) {
      final remote = await api.listMessages(conversationId);
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
    for (final event in pending) {
      final mutationId = const Uuid().v7();
      final payload = <String, dynamic>{
        'id': event.id,
        'title': event.title,
        'description': event.description,
        'location': event.location,
        'startAt': event.startAt,
        'endAt': event.endAt,
        'allDay': event.allDay,
      };
      Map<String, dynamic> result;
      if (event.syncStatus == 'pendingCreate') {
        result = await api.createSchedule(payload, mutationId);
      } else if (event.syncStatus == 'pendingDelete') {
        try {
          await api.deleteSchedule(event.id, mutationId);
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
        }
        result = <String, dynamic>{};
      } else {
        result = await api.updateSchedule(event.id, {
          ...payload,
          'baseVersion': event.remoteVersion,
        }, mutationId);
      }
      final remoteVersion =
          (result['version'] as num?)?.toInt() ?? event.remoteVersion;
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(event.id))).write(
        CalendarEventsCompanion(
          remoteVersion: Value(remoteVersion),
          syncStatus: const Value('synced'),
        ),
      );
    }
  }

  Future<int> _readCursor() async {
    final row = await (database.select(
      database.syncMetadata,
    )..where((item) => item.key.equals('serverCursor'))).getSingleOrNull();
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  Future<void> _writeCursor(int value) async {
    await database
        .into(database.syncMetadata)
        .insertOnConflictUpdate(
          SyncMetadataCompanion.insert(key: 'serverCursor', value: '$value'),
        );
  }
}
