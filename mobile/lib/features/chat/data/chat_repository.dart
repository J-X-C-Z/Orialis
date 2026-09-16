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

/// Local-first message storage. Network delivery and assistant responses are
/// deliberately owned by the main sync/chat integration layer.
class ChatRepository {
  ChatRepository({required this.database});

  final AppDatabase database;

  Stream<List<Message>> watchMessages(String conversationId) {
    return (database.select(database.messages)
          ..where((row) => row.conversationId.equals(conversationId))
          ..orderBy([(row) => OrderingTerm(expression: row.createdAt)]))
        .watch();
  }

  Future<Message> sendMessage({
    required String conversationId,
    required String content,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(content, 'content', 'Message cannot be empty');
    }

    final message = MessagesCompanion.insert(
      conversationId: conversationId,
      id: const Uuid().v7(),
      role: 'user',
      content: trimmed,
      createdAt: DateTime.now().toUtc().toIso8601String(),
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
}
