import '../data/chat_repository.dart';

enum ChatSendState { idle, sending, failed }

class ChatController {
  ChatController({required this.repository, required this.flush});

  final ChatRepository repository;
  final Future<void> Function() flush;
  ChatSendState state = ChatSendState.idle;
  Object? lastError;
  String? lastMessageId;

  Future<void> send({
    required String conversationId,
    required String content,
    String attachmentsJson = '[]',
  }) async {
    state = ChatSendState.sending;
    lastError = null;
    try {
      final message = await repository.sendMessage(
        conversationId: conversationId,
        content: content,
        attachmentsJson: attachmentsJson,
      );
      lastMessageId = message.id;
      await flush();
      state = ChatSendState.idle;
    } catch (error) {
      lastError = error;
      state = ChatSendState.failed;
      rethrow;
    }
  }

  Future<void> retry(String messageId) async {
    lastMessageId = messageId;
    state = ChatSendState.sending;
    lastError = null;
    try {
      await flush();
      state = ChatSendState.idle;
    } catch (error) {
      lastError = error;
      state = ChatSendState.failed;
      rethrow;
    }
  }
}
