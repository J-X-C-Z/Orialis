import 'package:flutter/material.dart';

import '../../../app/design/design_tokens.dart';
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
    final children = <Widget>[];
    children.add(_CompatibilityBadge(capabilities: store.capabilities));
    if (store.typing) {
      children.add(const _TypingCard());
    }
    if (store.agentStatus != null) {
      children.add(
        _StatusCard(
          status: store.agentStatus!,
          detail: store.agentStatusDetail,
        ),
      );
    }
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
    for (final request in store.approvals.values) {
      children.add(
        _ApprovalCard(request: request, store: store, onAction: onAction),
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
  }
}

class _CompatibilityBadge extends StatelessWidget {
  const _CompatibilityBadge({required this.capabilities});
  final AgentCapabilities capabilities;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.compact),
    child: Row(
      children: [
        Icon(
          capabilities.negotiated
              ? Icons.verified_outlined
              : Icons.sync_problem_outlined,
          size: AppIconSize.compact,
          color: AppColors.muted,
        ),
        const SizedBox(width: 4),
        Text(
          capabilities.label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: AppColors.muted),
        ),
      ],
    ),
  );
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.icon,
    required this.title,
    required this.child,
    this.color,
  });
  final IconData icon;
  final String title;
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.item),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: AppIconSize.control,
                  color: color ?? Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.controlGap),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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

class _TypingCard extends StatelessWidget {
  const _TypingCard();
  @override
  Widget build(BuildContext context) => const _EventCard(
    icon: Icons.more_horiz,
    title: 'Agent 正在输入',
    child: LinearProgressIndicator(minHeight: 3),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, this.detail});
  final String status;
  final String? detail;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.sync,
    title: 'Agent 状态：$status',
    child: Text(detail ?? '正在处理当前请求。'),
  );
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({required this.stream});
  final AgentStream stream;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: stream.error == null ? Icons.auto_awesome : Icons.error_outline,
    title: 'Agent · ${stream.displayStatus}',
    color: stream.error == null ? null : Theme.of(context).colorScheme.error,
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
    icon: Icons.account_tree_outlined,
    title: '工具时间线',
    child: Column(
      children: [
        for (final item in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              item.status == 'running'
                  ? Icons.timelapse
                  : Icons.check_circle_outline,
              size: AppIconSize.control,
            ),
            title: Text(item.name),
            subtitle: item.detail == null ? null : Text(item.detail!),
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
    icon: Icons.help_outline,
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
                OutlinedButton(
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
              child: TextField(
                controller: _controller,
                enabled: !_sending,
                decoration: const InputDecoration(hintText: '自定义回答'),
              ),
            ),
            const SizedBox(width: AppSpacing.controlGap),
            IconButton.filled(
              onPressed: _sending
                  ? null
                  : () => _submit(_controller.text.trim()),
              icon: const Icon(Icons.arrow_upward),
              tooltip: '提交回答',
            ),
          ],
        ),
        TextButton(
          onPressed: _sending ? null : () => _submit('取消'),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.request,
    required this.store,
    required this.onAction,
  });
  final ApprovalRequest request;
  final AgentEventStore store;
  final AgentActionCallback onAction;

  Future<void> _submit(String decision) async {
    if (!store.actions.claim(request.id)) return;
    try {
      await onAction('approval.response', request.id, {'decision': decision});
    } catch (_) {
      store.actions.release(request.id);
    }
  }

  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.verified_user_outlined,
    title: '需要审批',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(request.title),
        if (request.detail != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(request.detail!),
          ),
        const SizedBox(height: AppSpacing.controlGap),
        Wrap(
          spacing: AppSpacing.tight,
          runSpacing: AppSpacing.tight,
          children: [
            for (final value in const {
              'once': '这一次',
              'session': '本会话',
              'always': '总是允许',
              'deny': '拒绝',
            }.entries)
              FilledButton.tonal(
                onPressed: store.actions.contains(request.id)
                    ? null
                    : () => _submit(value.key),
                child: Text(value.value),
              ),
          ],
        ),
      ],
    ),
  );
}

class _CommandResultCard extends StatelessWidget {
  const _CommandResultCard({required this.result});
  final CommandResult result;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: result.ok ? Icons.terminal : Icons.error_outline,
    title: result.command,
    color: result.ok ? null : Theme.of(context).colorScheme.error,
    child: SelectableText(result.output.isEmpty ? '命令已完成。' : result.output),
  );
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});
  final SessionInfo session;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.forum_outlined,
    title: '会话：${session.title ?? session.id}',
    child: Text(
      '${session.event.replaceFirst('session.', '')}${session.status == null ? '' : ' · ${session.status}'}',
    ),
  );
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.artifact});
  final ArtifactInfo artifact;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.description_outlined,
    title: artifact.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (artifact.description != null) Text(artifact.description!),
        if (artifact.mimeType != null)
          Text(
            artifact.mimeType!,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        if (artifact.url != null)
          SelectableText(
            artifact.url!,
            style: Theme.of(context).textTheme.bodySmall,
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
    icon: Icons.notifications_outlined,
    title: '主动投递',
    child: Text(notice.message),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});
  final AgentError error;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.warning_amber_rounded,
    title: error.code,
    color: Theme.of(context).colorScheme.error,
    child: Text(error.message),
  );
}

class _FallbackCard extends StatelessWidget {
  const _FallbackCard({required this.event});
  final UnknownAgentEvent event;
  @override
  Widget build(BuildContext context) => _EventCard(
    icon: Icons.info_outline,
    title: '兼容提示 · ${event.kind}',
    child: const Text('当前客户端暂不认识此事件，已安全保留其摘要。'),
  );
}
