import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/domain/chat_transcript.dart';

Message _message(
  String text, {
  String role = 'assistant',
  String attachments = '[]',
}) => Message(
  conversationId: 'chat',
  id: 'message',
  role: role,
  content: text,
  createdAt: '2026-10-24T00:00:00Z',
  attachmentsJson: attachments,
  syncStatus: 'synced',
  remoteVersion: 1,
);

void main() {
  test('recognizes only Hermes notification envelopes', () {
    for (final content in [
      '⏳ Working — 3 min',
      '⏳ Working — 3 min — terminal',
      '⏳ Working — 3 min — iteration 1/60, research_market',
    ]) {
      expect(classifyChatText(content), ChatTextKind.progress);
      expect(isVisibleChatMessage(_message(content)), isFalse);
      expect(chatWorkingLabel(content), '正在思考 · 3 分钟');
    }
    expect(
      classifyChatText('💾 Self-improvement review: Memory updated'),
      ChatTextKind.internalNotice,
    );
    for (final content in [
      'Working with Flutter takes practice.',
      'We can hide self-improvement review notices.',
      '💾 Self-improvement review: Memory updated',
      '⏳ Working — 3 min',
    ]) {
      expect(isVisibleChatMessage(_message(content, role: 'user')), isTrue);
    }
    expect(classifyChatText('Working with Flutter'), ChatTextKind.message);
    expect(
      classifyChatText('Self-improvement review is an internal process.'),
      ChatTextKind.message,
    );
    expect(
      classifyChatText('⏳ Working — 3 min\n\nHere is the actual result.'),
      ChatTextKind.message,
    );
    expect(
      isVisibleChatMessage(
        _message('⏳ Working — 3 min', attachments: '[{"id":"file"}]'),
      ),
      isTrue,
    );
  });
}
