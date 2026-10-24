import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/agent_event_state.dart';
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

/// One ephemeral status line; only its text mask repaints on animation frames.
class ChatThinkingIndicator extends StatefulWidget {
  const ChatThinkingIndicator({required this.label, super.key});
  final String label;

  @override
  State<ChatThinkingIndicator> createState() => _ChatThinkingIndicatorState();
}

class _ChatThinkingIndicatorState extends State<ChatThinkingIndicator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _phase = AnimationController(
    vsync: this,
    duration: LuminaMotion.standard * 8,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _updateAnimation() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final active = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (!active ||
        !TickerMode.valuesOf(context).enabled ||
        LuminaTheme.motionReducedOf(context)) {
      _phase.stop();
    } else if (!_phase.isAnimating) {
      _phase.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _updateAnimation();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final style = theme.textTheme.bodySmall.copyWith(color: theme.colors.ink);
    final text = Text(widget.label, style: style);
    return Semantics(
      liveRegion: true,
      label: widget.label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: RepaintBoundary(
            child: LuminaTheme.motionReducedOf(context)
                ? Text(
                    widget.label,
                    style: style.copyWith(
                      color: theme.colors.ink.withValues(alpha: .45),
                    ),
                  )
                : AnimatedBuilder(
                    animation: _phase,
                    child: text,
                    builder: (context, child) => ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) =>
                          LinearGradient(
                            colors: [
                              theme.colors.ink.withValues(alpha: .32),
                              theme.colors.ink.withValues(alpha: .72),
                              theme.colors.ink.withValues(alpha: .32),
                            ],
                          ).createShader(
                            Rect.fromLTWH(
                              bounds.left +
                                  bounds.width * (_phase.value * 3 - 1),
                              bounds.top,
                              bounds.width,
                              bounds.height,
                            ),
                          ),
                      child: child,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
