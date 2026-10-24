import '../../../core/database/app_database.dart';

enum ChatTextKind { message, progress, internalNotice }

// Legacy Hermes messages have no visibility metadata after server persistence.
// Match its notification envelopes, never ordinary mentions of these phrases.
final _workingNotice = RegExp(
  r'^⏳\s*Working\s*[—–-]\s*(\d+)\s*min\b[^\r\n]*$',
  caseSensitive: false,
);
final _reviewNotice = RegExp(
  r'^💾\s*Self-improvement review:\s+\S',
  caseSensitive: false,
);

ChatTextKind classifyChatText(String content) {
  final text = content.trim();
  if (_workingNotice.hasMatch(text)) return ChatTextKind.progress;
  if (_reviewNotice.hasMatch(text)) return ChatTextKind.internalNotice;
  return ChatTextKind.message;
}

bool isVisibleChatMessage(Message message) =>
    (message.role != 'assistant' && message.role != 'system') ||
    message.attachmentsJson.trim() != '[]' ||
    classifyChatText(message.content) == ChatTextKind.message;

String? chatWorkingLabel(String? content) {
  if (content == null) return null;
  final match = _workingNotice.firstMatch(content.trim());
  return match == null ? null : '正在思考 · ${match.group(1)} 分钟';
}
