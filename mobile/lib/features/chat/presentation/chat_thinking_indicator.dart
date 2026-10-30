import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/agent_event_state.dart';
import '../../../app/design/chat_symbols.dart';
import '../domain/chat_transcript.dart';

String? chatThinkingLabel(AgentEventStore store) {
  final status = store.agentStatus?.toLowerCase();
  switch (status) {
    case 'idle':
    case 'ready':
    case 'unknown':
    case 'completed':
    case 'complete':
    case 'done':
    case 'failed':
    case 'error':
    case 'timeout':
    case 'cancelled':
    case 'canceled':
    case 'stopped':
    case 'ended':
      return null;
    case 'waiting':
    case 'queued':
      return store.approvals.isNotEmpty || store.clarifications.isNotEmpty
          ? null
          : '等待处理';
    case 'responding':
    case 'generating':
    case 'streaming':
    case 'typing':
      return '正在回复';
    case 'thinking':
    case 'reasoning':
    case 'running':
    case 'working':
    case 'processing':
    case 'busy':
      return chatWorkingLabel(store.agentStatusDetail) ?? '正在思考';
  }
  return store.typing ||
          store.streams.values.any((stream) => !stream.complete) ||
          store.tools.values.any((tool) => tool.status == 'running')
      ? '正在思考'
      : null;
}

/// A stationary label with one gently breathing status glyph.
class ChatThinkingIndicator extends StatelessWidget {
  const ChatThinkingIndicator({required this.label, super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final reduced = LuminaTheme.motionReducedOf(context);
    final kind = label.contains('回复')
        ? ChatSymbolKind.send
        : label.contains('等待')
        ? ChatSymbolKind.working
        : ChatSymbolKind.thinking;
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            ChatSymbol(kind, size: 18, animated: !reduced),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall.copyWith(
                  color: theme.colors.ink.withValues(alpha: .65),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
