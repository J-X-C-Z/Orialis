import '../../../app/design/design_components.dart';

import '../domain/agent_event_state.dart';
import 'safe_markdown.dart';

typedef AgentActionCallback =
    Future<void> Function(
      String type,
      String requestId,
      Map<String, dynamic> payload,
    );

class AgentEventsPanel extends StatelessWidget {
  const AgentEventsPanel({
    required this.store,
    required this.onAction,
    super.key,
  });
  final AgentEventStore store;
  final AgentActionCallback onAction;

  @override
  Widget build(BuildContext context) {
    // Stream deltas only wake this panel; the chat page chrome stays put.
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final children = <Widget>[];
        for (final stream in store.streams.values) {
          if (stream.text.isNotEmpty || stream.error != null) {
            children.add(_StreamCard(stream: stream));
          }
        }
        if (store.tools.isNotEmpty) {
          children.add(_ToolTimelineCard(items: store.tools.values.toList()));
        }
        for (final request in store.clarifications.values) {
          children.add(
            _ClarifyCard(request: request, store: store, onAction: onAction),
          );
        }
        for (final result in store.commandResults.values) {
          children.add(_CommandResultCard(result: result));
        }
        for (final session in store.sessions.values) {
          children.add(_SessionCard(session: session));
        }
        for (final artifact in store.artifacts.values) {
          children.add(_ArtifactCard(artifact: artifact));
        }
        for (final notice in store.deliveryNotices) {
          children.add(_NoticeCard(notice: notice));
        }
        for (final error in store.errors) {
          children.add(_ErrorCard(error: error));
        }
        for (final event in store.fallbacks) {
          children.add(_FallbackCard(event: event));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Column(children: [for (final child in children) child]);
      },
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.icon,
    required this.title,
    required this.child,
    this.color,
  });
  final LuminaIcons icon;
  final String title;
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.item),
      child: LuminaSurface(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                LuminaIcon(
                  icon,
                  size: AppIconSize.control,
                  color: color ?? LuminaTheme.of(context).colors.accent,
                ),
                const SizedBox(width: AppSpacing.controlGap),
                Expanded(
                  child: Text(
                    title,
                    style: LuminaTheme.of(context).textTheme.titleSmall
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.controlGap),
            child,
          ],
        ),
      ),
    );
  }
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({required this.stream});
  final AgentStream stream;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: stream.error == null ? LuminaIcons.sparkles : LuminaIcons.error,
    title: stream.error == null ? 'Orialis' : '回复未完成',
    color: stream.error == null ? null : LuminaTheme.of(context).colors.danger,
    child: stream.error == null
        ? SafeMarkdownView(source: stream.text, fallback: stream.hasGap)
        : Text(stream.error!),
  );
}

class _ToolTimelineCard extends StatelessWidget {
  const _ToolTimelineCard({required this.items});
  final List<ToolTimelineItem> items;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.branch,
    title: '工具时间线',
    child: Column(
      children: [
        for (final item in items)
          OrialisListRow(
            leading: LuminaIcon(
              item.status == 'running'
                  ? LuminaIcons.clock
                  : LuminaIcons.checkCircle,
              size: AppIconSize.control,
            ),
            title: item.name,
            subtitle: item.detail,
            trailing: Text(
              item.status == 'running'
                  ? '运行中'
                  : item.status == 'completed'
                  ? '完成'
                  : item.status,
            ),
          ),
      ],
    ),
  );
}

class _ClarifyCard extends StatefulWidget {
  const _ClarifyCard({
    required this.request,
    required this.store,
    required this.onAction,
  });
  final ClarificationRequest request;
  final AgentEventStore store;
  final AgentActionCallback onAction;
  @override
  State<_ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends State<_ClarifyCard> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String value) async {
    if (_sending || !widget.store.actions.claim(widget.request.id)) return;
    setState(() => _sending = true);
    try {
      await widget.onAction('clarify.response', widget.request.id, {
        'answer': value,
      });
    } catch (_) {
      widget.store.actions.release(widget.request.id);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.info,
    title: '需要你补充信息',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.request.question),
        if (widget.request.options.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.controlGap),
          Wrap(
            spacing: AppSpacing.controlGap,
            runSpacing: AppSpacing.tight,
            children: [
              for (final option in widget.request.options)
                LuminaButton(
                  onPressed: _sending ? null : () => _submit(option),
                  child: Text(option),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.controlGap),
        Row(
          children: [
            Expanded(
              child: LuminaTextField(
                controller: _controller,
                enabled: !_sending,
                hintText: '自定义回答',
              ),
            ),
            const SizedBox(width: AppSpacing.controlGap),
            LuminaIconButton(
              onPressed: _sending
                  ? null
                  : () => _submit(_controller.text.trim()),
              icon: const LuminaIcon(LuminaIcons.send),
              tooltip: '提交回答',
            ),
          ],
        ),
        LuminaButton(
          onPressed: _sending ? null : () => _submit('取消'),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// Protected actions stay in one explicit sheet, outside the message content.
class AgentApprovalSheet extends StatefulWidget {
  const AgentApprovalSheet({
    required this.request,
    required this.store,
    required this.onAction,
    super.key,
  });
  final ApprovalRequest request;
  final AgentEventStore store;
  final AgentActionCallback onAction;
  @override
  State<AgentApprovalSheet> createState() => _AgentApprovalSheetState();
}

class _AgentApprovalSheetState extends State<AgentApprovalSheet> {
  bool _sending = false;
  String? _error;
  Future<void> _submit(String decision) async {
    if (_sending || !widget.store.actions.claim(widget.request.id)) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onAction('approval.response', widget.request.id, {
        'decision': decision,
      });
    } catch (_) {
      widget.store.actions.release(widget.request.id);
      if (mounted) {
        setState(() {
          _sending = false;
          _error = '暂时无法发送，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Row(
        children: [
          LuminaIcon(LuminaIcons.shield),
          SizedBox(width: 12),
          Text(
            '审批请求',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text(widget.request.title),
      if (widget.request.detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.request.detail!,
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: 20),
      for (final value in const {
        'once': '这一次',
        'session': '本会话',
        'always': '总是允许',
        'deny': '拒绝',
      }.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: LuminaButton(
            primary: value.key != 'deny',
            onPressed: _sending ? null : () => _submit(value.key),
            child: Text(value.value),
          ),
        ),
      if (_sending) const Center(child: LuminaProgress()),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: LuminaTheme.of(context).colors.danger),
        ),
    ],
  );
}

class _CommandResultCard extends StatelessWidget {
  const _CommandResultCard({required this.result});
  final CommandResult result;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: result.ok ? LuminaIcons.terminal : LuminaIcons.error,
    title: result.command,
    color: result.ok ? null : LuminaTheme.of(context).colors.danger,
    child: LuminaSelectableText(
      result.output.isEmpty ? '命令已完成。' : result.output,
    ),
  );
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});
  final SessionInfo session;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.chat,
    title: '会话：${session.title ?? session.id}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${session.event.replaceFirst('session.', '')}'
          '${session.status == null ? '' : ' · ${session.status}'}'
          '${session.command == null ? '' : ' · ${session.command}'}',
        ),
        if (session.message != null && session.message!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LuminaSelectableText(session.message!.trim()),
          ),
      ],
    ),
  );
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.artifact});
  final ArtifactInfo artifact;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.file,
    title: artifact.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (artifact.description != null) Text(artifact.description!),
        if (artifact.mimeType != null)
          Text(
            artifact.mimeType!,
            style: LuminaTheme.of(context).textTheme.labelSmall,
          ),
        if (artifact.url != null)
          LuminaSelectableText(
            artifact.url!,
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
      ],
    ),
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});
  final DeliveryNotice notice;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.notification,
    title: '主动投递',
    child: Text(notice.message),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});
  final AgentError error;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.warning,
    title: error.code,
    color: LuminaTheme.of(context).colors.danger,
    child: Text(error.message),
  );
}

class _FallbackCard extends StatelessWidget {
  const _FallbackCard({required this.event});
  final UnknownAgentEvent event;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.info,
    title: '兼容提示 · ${event.kind}',
    child: const Text('当前客户端暂不认识此事件，已安全保留其摘要。'),
  );
}
