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
    String? replyToMessageId,
    String? replyQuote,
    String? replyRole,
  }) async {
    state = ChatSendState.sending;
    lastError = null;
    try {
      final message = await repository.sendMessage(
        conversationId: conversationId,
        content: content,
        attachmentsJson: attachmentsJson,
        replyToMessageId: replyToMessageId,
        replyQuote: replyQuote,
        replyRole: replyRole,
      );
      lastMessageId = message.id;
      await _flushMessage(conversationId, message.id);
      state = ChatSendState.idle;
    } catch (error) {
      lastError = error;
      state = ChatSendState.failed;
      rethrow;
    }
  }

  Future<void> retry(String messageId, {required String conversationId}) async {
    lastMessageId = messageId;
    state = ChatSendState.sending;
    lastError = null;
    try {
      await _flushMessage(conversationId, messageId);
      state = ChatSendState.idle;
    } catch (error) {
      lastError = error;
      state = ChatSendState.failed;
      rethrow;
    }
  }

  Future<void> _flushMessage(String conversationId, String messageId) async {
    try {
      await flush();
    } catch (_) {
      // Other sync domains may fail after this message was acknowledged.
      if (!await repository.isMessageUploaded(conversationId, messageId)) {
        rethrow;
      }
    }
  }
}
