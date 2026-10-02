import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

final chatMessagesProvider =
    StreamProvider.family<
      List<Message>,
      ({ChatRepository repository, String conversationId})
    >((ref, query) {
      return query.repository.watchMessages(query.conversationId);
    });

final chatLatestMessageProvider =
    StreamProvider.family<
      Message?,
      ({ChatRepository repository, String conversationId})
    >(
      (ref, query) => query.repository.watchLatestMessage(query.conversationId),
    );

final chatConversationsProvider =
    StreamProvider.family<List<Conversation>, ChatRepository>(
      (ref, repository) => repository.watchConversations(),
    );

/// Local-first message storage. Network delivery and assistant responses are
/// deliberately owned by the main sync/chat integration layer.
class ChatRepository {
  ChatRepository({required this.database});

  final AppDatabase database;

  Future<void> setPinned(Conversation conversation, bool pinned) async {
    final current =
        await (database.select(database.conversations)..where(
              (r) => r.id.equals(conversation.id) & r.deletedAt.isNull(),
            ))
            .getSingle();
    await (database.update(
      database.conversations,
    )..where((r) => r.id.equals(current.id))).write(
      ConversationsCompanion(
        pinned: Value(pinned),
        manualPosition: const Value(null),
        localRevision: Value(current.localRevision + 1),
        syncStatus: Value(_statusAfterLocalEdit(current.syncStatus)),
      ),
    );
  }

  Future<void> reorderPinnedConversations(List<String> ids) =>
      _setConversationOrder(ids, false);
  Future<void> resetConversationOrder() async {
    final rows = await (database.select(
      database.conversations,
    )..where((r) => r.pinned.equals(true) & r.deletedAt.isNull())).get();
    await _setConversationOrder(rows.map((r) => r.id).toList(), true);
  }

  Future<void> _setConversationOrder(List<String> ids, bool reset) async {
    if (ids.toSet().length != ids.length) throw ArgumentError('Duplicate IDs');
    await database.transaction(() async {
      for (var i = 0; i < ids.length; i++) {
        final current =
            await (database.select(database.conversations)
                  ..where((r) => r.id.equals(ids[i]) & r.deletedAt.isNull()))
                .getSingle();
        if (!current.pinned) {
          throw StateError('Only pinned conversations can be reordered');
        }
        await (database.update(
          database.conversations,
        )..where((r) => r.id.equals(current.id))).write(
          ConversationsCompanion(
            manualPosition: Value(reset ? null : i),
            localRevision: Value(current.localRevision + 1),
            syncStatus: Value(_statusAfterLocalEdit(current.syncStatus)),
          ),
        );
      }
    });
  }

  Stream<List<Conversation>> watchConversations() =>
      database.watchActiveConversations();

  /// Import a conversation only after the server has confirmed its device binding.
  Future<Conversation> importDeviceConversation(
    Map<String, dynamic> remote,
  ) async {
    final id = remote['id'] as String;
    await database
        .into(database.conversations)
        .insertOnConflictUpdate(
          ConversationsCompanion.insert(
            id: id,
            title: remote['title'] as String,
            type: Value(remote['type'] as String? ?? 'normal'),
            createdAt: remote['createdAt'] as String,
            updatedAt: remote['updatedAt'] as String,
            remoteVersion: Value((remote['version'] as num).toInt()),
            syncStatus: const Value('synced'),
          ),
        );
    return (database.select(
      database.conversations,
    )..where((row) => row.id.equals(id))).getSingle();
  }

  Future<Conversation> createConversation({String? title}) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final conversation = ConversationsCompanion.insert(
      id: const Uuid().v7(),
      title: title?.trim().isNotEmpty == true ? title!.trim() : '新会话',
      type: const Value('normal'),
      createdAt: timestamp,
      updatedAt: timestamp,
      localRevision: const Value(1),
      syncStatus: const Value('pendingCreate'),
    );
    await database.into(database.conversations).insert(conversation);
    return (database.select(
      database.conversations,
    )..where((row) => row.id.equals(conversation.id.value))).getSingle();
  }

  Future<void> renameConversation(Conversation conversation, String title) {
    return (database.update(
      database.conversations,
    )..where((row) => row.id.equals(conversation.id))).write(
      ConversationsCompanion(
        title: Value(title.trim()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(conversation.localRevision + 1),
        syncStatus: Value(_statusAfterLocalEdit(conversation.syncStatus)),
      ),
    );
  }

  Future<void> deleteConversation(Conversation conversation) async {
    if (conversation.type == 'main' || conversation.id == 'default') {
      throw StateError('主会话不能删除');
    }
    await (database.update(
      database.conversations,
    )..where((row) => row.id.equals(conversation.id))).write(
      ConversationsCompanion(
        deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(conversation.localRevision + 1),
        syncStatus: const Value('pendingDelete'),
      ),
    );
  }

  Stream<Message?> watchLatestMessage(String conversationId) =>
      (database.select(database.messages)
            ..where((r) => r.conversationId.equals(conversationId))
            ..orderBy([
              (r) => OrderingTerm.desc(r.createdAt),
              (r) => OrderingTerm.desc(r.id),
            ])
            ..limit(1))
          .watchSingleOrNull();

  Stream<List<Message>> watchMessages(String conversationId) {
    return (database.select(database.messages)
          ..where((row) => row.conversationId.equals(conversationId))
          ..orderBy([(row) => OrderingTerm(expression: row.createdAt)]))
        .watch();
  }

  String _statusAfterLocalEdit(String current) =>
      current == 'pendingCreate' ? 'pendingCreate' : 'pendingUpdate';

  Future<Message> sendMessage({
    required String conversationId,
    required String content,
    String attachmentsJson = '[]',
    String? replyToMessageId,
    String? replyQuote,
    String? replyRole,
  }) async {
    final trimmed = content.trim();
    final hasAttachments =
        (jsonDecode(attachmentsJson) as List<dynamic>?)?.isNotEmpty ?? false;
    if (trimmed.isEmpty && !hasAttachments) {
      throw ArgumentError.value(content, 'content', 'Message cannot be empty');
    }

    final message = MessagesCompanion.insert(
      conversationId: conversationId,
      id: const Uuid().v7(),
      role: 'user',
      content: trimmed,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      attachmentsJson: Value(attachmentsJson),
      replyToMessageId: Value(replyToMessageId),
      replyQuote: Value(replyQuote),
      replyRole: Value(replyRole),
      syncStatus: const Value('pendingCreate'),
    );
    await database.into(database.messages).insert(message);
    return (database.select(database.messages)..where(
          (row) =>
              row.conversationId.equals(conversationId) &
              row.id.equals(message.id.value),
        ))
        .getSingle();
  }

  /// Persists a message received from the server's authenticated realtime
  /// channel. A queued local mutation always wins over a realtime echo.
  Future<void> applyRemoteMessage(Map<String, dynamic> payload) async {
    final conversationId = payload['conversationId'] as String?;
    final id = payload['id'] as String?;
    final role = payload['role'] as String?;
    final content = payload['content'] as String?;
    final createdAt = payload['createdAt'] as String?;
    if (conversationId == null ||
        id == null ||
        role == null ||
        content == null ||
        createdAt == null) {
      return;
    }

    final remoteVersion = (payload['version'] as num?)?.toInt() ?? 1;
    final existing =
        await (database.select(database.messages)..where(
              (row) =>
                  row.conversationId.equals(conversationId) & row.id.equals(id),
            ))
            .getSingleOrNull();
    if (existing != null && existing.syncStatus != 'synced') return;
    if (existing != null && existing.remoteVersion >= remoteVersion) return;

    await database
        .into(database.messages)
        .insertOnConflictUpdate(
          MessagesCompanion.insert(
            conversationId: conversationId,
            id: id,
            role: role,
            content: content,
            createdAt: createdAt,
            attachmentsJson: Value(
              jsonEncode(payload['attachments'] ?? const []),
            ),
            replyToMessageId: Value(payload['replyToMessageId'] as String?),
            replyQuote: Value(payload['replyQuote'] as String?),
            replyRole: Value(payload['replyRole'] as String?),
            remoteVersion: Value(remoteVersion),
            syncStatus: const Value('synced'),
          ),
        );
  }
}
