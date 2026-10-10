part of 'sync_engine.dart';

extension ChatSyncHandler on SyncEngine {
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
          pinned: conversation.pinned,
          manualPosition: conversation.manualPosition,
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
          pinned: conversation.pinned,
          manualPosition: conversation.manualPosition,
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
              pinned: Value(value['pinned'] as bool? ?? false),
              manualPosition: Value((value['manualPosition'] as num?)?.toInt()),
              createdAt: createdAt,
              updatedAt: updatedAt,
              version: Value(remoteVersion),
              remoteVersion: Value(remoteVersion),
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
          replyToMessageId: message.replyToMessageId,
          replyQuote: message.replyQuote,
          replyRole: message.replyRole,
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
                replyToMessageId: Value(value['replyToMessageId'] as String?),
                replyQuote: Value(value['replyQuote'] as String?),
                replyRole: Value(value['replyRole'] as String?),
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
}
