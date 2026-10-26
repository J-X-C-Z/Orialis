import '../../../core/database/app_database.dart';

enum ChatTextKind { message, progress, internalNotice }

final _summaryMessageId = RegExp(r'^progress_[a-f0-9]{24}$');
final _finalMessageId = RegExp(r'^final_[a-f0-9]{24}$');

bool isChatProgressSummary(Message message) =>
    message.role == 'assistant' && _summaryMessageId.hasMatch(message.id);

// Stream completion can be a mid-turn boundary; only a durable turn-final ID counts.
Set<String> completedSummaryAnchors(Iterable<Message> messages) => {
  for (final message in messages)
    if (message.role == 'assistant' &&
        _finalMessageId.hasMatch(message.id) &&
        message.replyToMessageId?.isNotEmpty == true)
      message.replyToMessageId!,
};

// Legacy Hermes messages have no visibility metadata after server persistence.
// Match its notification envelopes, never ordinary mentions of these phrases.
final _workingNotice = RegExp(
  r'^⏳\s*(?:Working\s*[—–-]|正在处理\s*——)\s*(\d+)\s*(?:min\b|分钟)[^\r\n]*$',
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
