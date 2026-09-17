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

final chatConversationsProvider =
    StreamProvider.family<List<Conversation>, ChatRepository>(
      (ref, repository) => repository.watchConversations(),
    );

/// Local-first message storage. Network delivery and assistant responses are
/// deliberately owned by the main sync/chat integration layer.
class ChatRepository {
  ChatRepository({required this.database});

  final AppDatabase database;

  Stream<List<Conversation>> watchConversations() =>
      database.watchActiveConversations();

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
            remoteVersion: Value(remoteVersion),
            syncStatus: const Value('synced'),
          ),
        );
  }
}
