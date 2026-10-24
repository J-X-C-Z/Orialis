import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/agent_event_state.dart';

/// Displays only status and tool events actually reported by the agent.
class ChatActivityPanel extends StatefulWidget {
  const ChatActivityPanel({required this.store, this.onRefresh, super.key});
  final AgentEventStore store;
  final Future<void> Function()? onRefresh;

  @override
  State<ChatActivityPanel> createState() => _ChatActivityPanelState();
}

class _ChatActivityPanelState extends State<ChatActivityPanel> {
  bool _expanded = false;
  bool _refreshing = false;
  String? _refreshError;
  DateTime? _refreshedAt;
  int _refreshGeneration = 0;

  @override
  void didUpdateWidget(ChatActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _refreshGeneration++;
      _expanded = false;
      _refreshing = false;
      _refreshError = null;
      _refreshedAt = null;
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || widget.onRefresh == null) return;
    final generation = ++_refreshGeneration;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      await widget.onRefresh!();
      if (!mounted || generation != _refreshGeneration) return;
      setState(() => _refreshedAt = DateTime.now());
    } on Object {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() => _refreshError = '刷新失败，请重试');
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final tools = store.tools.values.toList();
    final running = tools.where((item) => item.status == 'running').length;
    final failed = tools
        .where((item) => item.status == 'failed' || item.status == 'error')
        .length;
    final status = _status(store);
    final reduced = LuminaTheme.motionReducedOf(context);
    final duration = reduced ? Duration.zero : LuminaMotion.fast;
    final hasDetails = tools.isNotEmpty || store.agentStatusDetail != null;
    final title = tools.isEmpty ? '运行状态' : '工具活动 · ${tools.length}';
    final details = !_expanded || !hasDetails
        ? const SizedBox(width: double.infinity)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '处理过程',
                  style: LuminaTheme.of(context).textTheme.labelMedium,
                ),
              ),
              if (store.agentStatusDetail case final detail?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LuminaSelectableText(detail),
                ),
              for (final item in tools)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: LuminaTheme.of(context).textTheme.labelMedium,
                      ),
                      Text(
                        _toolStatus(item.status),
                        style: LuminaTheme.of(context).textTheme.labelSmall,
                      ),
                      if (item.detail != null)
                        LuminaSelectableText(item.detail!),
                    ],
                  ),
                ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  button: hasDetails,
                  expanded: hasDetails ? _expanded : null,
                  child: LuminaTap(
                    onTap: hasDetails
                        ? () => setState(() => _expanded = !_expanded)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: LuminaTheme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ),
                              if (hasDetails)
                                LuminaIcon(
                                  _expanded
                                      ? LuminaIcons.chevronDown
                                      : LuminaIcons.chevronRight,
                                  size: 18,
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: luminaEaseOut,
                            switchOutCurve: luminaEaseOut,
                            child: Align(
                              key: ValueKey(status),
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                status,
                                style: LuminaTheme.of(context)
                                    .textTheme
                                    .bodySmall,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.onRefresh != null) ...[
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: '刷新运行状态',
                  child: LuminaButton(
                    primary: false,
                    onPressed: _refreshing ? null : _refresh,
                    child: Text(_refreshing ? '刷新中' : '刷新'),
                  ),
                ),
              ],
            ],
          ),
          if (tools.isNotEmpty)
            Text(
              '$running 项运行中 · $failed 项失败',
              style: LuminaTheme.of(context).textTheme.bodySmall,
            ),
          if (_refreshError != null)
            Text(
              _refreshError!,
              style: TextStyle(color: LuminaTheme.of(context).colors.danger),
            ),
          if (_refreshedAt != null && _refreshError == null)
            Text(
              '已刷新 ${_time(_refreshedAt!)}',
              style: LuminaTheme.of(context).textTheme.labelSmall,
            ),
          // Accordion height alone animates; token deltas never become animation triggers.
          if (reduced)
            details
          else
            AnimatedSize(
              duration: duration,
              curve: luminaEaseOut,
              alignment: Alignment.topCenter,
              child: details,
            ),
        ],
      ),
    );
  }
}

String _status(AgentEventStore store) {
  final reported = switch (store.agentStatus) {
    'thinking' || 'reasoning' => '思考中',
    'running' || 'working' || 'processing' || 'busy' => '正在处理',
    'responding' || 'generating' || 'streaming' || 'typing' => '正在回复',
    'waiting' || 'queued' => '等待处理',
    'idle' || 'ready' => '空闲',
    'completed' || 'complete' || 'done' => '已完成',
    'failed' || 'error' => '处理失败',
    'cancelled' || 'canceled' || 'stopped' => '已停止',
    _ => store.agentStatus == null ? null : '暂无实时状态',
  };
  if (reported != null) return reported;
  if (store.typing) return '正在回复';
  if (store.streams.values.any((stream) => !stream.complete)) return '正在处理';
  if (store.tools.values.any((tool) => tool.status == 'running')) {
    return '正在使用工具';
  }
  if (store.streams.values.any((stream) => stream.error != null)) return '处理失败';
  if (store.streams.isNotEmpty &&
      store.streams.values.every((stream) => stream.complete)) {
    return '已完成';
  }
  return '暂无实时状态';
}

String _toolStatus(String value) => switch (value) {
  'running' => '运行中',
  'completed' || 'complete' || 'done' => '完成',
  'failed' || 'error' => '失败',
  _ => value,
};

String _time(DateTime value) => [
  value.hour,
  value.minute,
  value.second,
].map((part) => part.toString().padLeft(2, '0')).join(':');
