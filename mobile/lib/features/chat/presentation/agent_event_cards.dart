import 'dart:convert';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/agent_event_state.dart';
import 'chat_activity_panel.dart';
import 'safe_markdown.dart';

typedef AgentActionCallback = Future<void> Function(
  String type,
  String requestId,
  Map<String, dynamic> payload,
);

class AgentEventsPanel extends StatelessWidget {
  const AgentEventsPanel({
    required this.store,
    required this.onAction,
    this.showClarifications = true,
    this.persistedMessageIds = const {},
    this.onPromptSelected,
    this.onRefresh,
    this.showActivity = true,
    super.key,
  });
  final AgentEventStore store;
  final AgentActionCallback onAction;
  final bool showClarifications;
  final Set<String> persistedMessageIds;
  final ValueChanged<String>? onPromptSelected;
  final Future<void> Function()? onRefresh;
  final bool showActivity;

  @override
  Widget build(BuildContext context) {
    // Stream deltas only wake this panel; the chat page chrome stays put.
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final children = <Widget>[];
        if (showActivity &&
            (onRefresh != null ||
                store.typing ||
                store.agentStatus != null ||
                store.agentStatusDetail != null ||
                store.streams.isNotEmpty ||
                store.tools.isNotEmpty)) {
          children.add(
            ChatActivityPanel(
              key: const ValueKey('chat-activity'),
              store: store,
              onRefresh: onRefresh,
            ),
          );
        }
        for (final stream in store.streams.values) {
          if (stream.complete &&
              stream.error == null &&
              persistedMessageIds.contains(stream.messageId)) {
            continue;
          }
          if (stream.text.isNotEmpty || stream.error != null) {
            children.add(
              _StreamCard(
                key: ValueKey('stream-${stream.id}'),
                stream: stream,
                onPromptSelected: stream.complete ? onPromptSelected : null,
              ),
            );
          }
        }
        for (final request
            in showClarifications
                ? store.clarifications.values
                : const <ClarificationRequest>[]) {
          children.add(
            _ClarifyCard(
              key: ValueKey('clarify-${request.id}'),
              request: request,
              store: store,
              onAction: onAction,
            ),
          );
        }
        for (final result in store.commandResults.values) {
          children.add(_CommandResultCard(result: result));
        }
        for (final session in store.sessions.values) {
          if (session.statusSnapshot) continue;
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

/// Approvals and questions share one place above the message composer.
class AgentRequestsPanel extends StatefulWidget {
  const AgentRequestsPanel({
    required this.store,
    required this.onAction,
    super.key,
  });
  final AgentEventStore store;
  final AgentActionCallback onAction;

  @override
  State<AgentRequestsPanel> createState() => _AgentRequestsPanelState();
}

class _AgentRequestsPanelState extends State<AgentRequestsPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      final count = store.approvals.length + store.clarifications.length;
      if (count == 0) return const SizedBox.shrink();
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .35,
        ),
        child: SingleChildScrollView(
          child: LuminaExpandableCard(
            expanded: _expanded,
            onExpand: () => setState(() => _expanded = true),
            header: LuminaListRow(
              title: '待处理请求 · $count',
              leading: const LuminaIcon(LuminaIcons.notification),
              trailing: LuminaIcon(
                _expanded ? LuminaIcons.chevronDown : LuminaIcons.chevronRight,
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            summary: const Text('展开查看审批与补充问题'),
            detailBuilder: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final request in store.approvals.values)
                  Padding(
                    key: ValueKey('approval-${request.id}'),
                    padding: const EdgeInsets.only(bottom: LuminaSpacing.item),
                    child: AgentApprovalSheet(
                      request: request,
                      store: store,
                      onAction: widget.onAction,
                    ),
                  ),
                for (final request in store.clarifications.values)
                  _ClarifyCard(
                    key: ValueKey('clarify-${request.id}'),
                    request: request,
                    store: store,
                    onAction: widget.onAction,
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
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
      padding: const EdgeInsets.only(bottom: LuminaSpacing.item),
      child: LuminaSurface(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                LuminaIcon(
                  icon,
                  size: LuminaIconSize.control,
                  color: color ?? LuminaTheme.of(context).colors.accent,
                ),
                const SizedBox(width: LuminaSpacing.controlGap),
                Expanded(
                  child: Text(
                    title,
                    style: LuminaTheme.of(context).textTheme.titleSmall
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LuminaSpacing.controlGap),
            child,
          ],
        ),
      ),
    );
  }
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({required this.stream, this.onPromptSelected, super.key});
  final AgentStream stream;
  final ValueChanged<String>? onPromptSelected;
  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('assistant-stream-${stream.id}'),
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          stream.error == null ? 'Orialis' : '回复未完成',
          style: LuminaTheme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        stream.error == null
            ? SafeMarkdownView(
                source: stream.text,
                fallback: stream.hasGap,
                allowResponseUi: true,
                onPromptSelected: onPromptSelected,
              )
            : Text(
                stream.error!,
                style: TextStyle(color: LuminaTheme.of(context).colors.danger),
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
    super.key,
  });
  final ClarificationRequest request;
  final AgentEventStore store;
  final AgentActionCallback onAction;
  @override
  State<_ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends State<_ClarifyCard> {
  final _controller = TextEditingController();
  final Set<String> _selected = {};
  bool _sending = false;
  String? _error;
  bool get _disabled =>
      _sending || widget.store.actions.contains(widget.request.id);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String value, {bool cancel = false}) async {
    if (value.trim().isEmpty ||
        _disabled ||
        !widget.store.actions.claim(widget.request.id)) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onAction(
        cancel ? 'clarify.cancel' : 'clarify.response',
        widget.request.id,
        {if (cancel) 'reason': 'cancelled' else 'answer': value},
      );
      if (mounted) setState(() => _sending = false);
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
  Widget build(BuildContext context) => _EventCard(
    icon: LuminaIcons.info,
    title: '需要你补充信息',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.request.question),
        if (widget.request.options.isNotEmpty) ...[
          const SizedBox(height: LuminaSpacing.controlGap),
          Wrap(
            spacing: LuminaSpacing.controlGap,
            runSpacing: LuminaSpacing.tight,
            children: [
              for (final option in widget.request.options)
                if (widget.request.multiSelect)
                  LuminaChip(
                    label: Text(option),
                    selected: _selected.contains(option),
                    onSelected: _disabled
                        ? null
                        : (selected) => setState(() {
                            if (selected) {
                              _selected.add(option);
                            } else {
                              _selected.remove(option);
                            }
                          }),
                  )
                else
                  LuminaButton(
                    onPressed: _disabled ? null : () => _submit(option),
                    child: Text(option),
                  ),
            ],
          ),
        ],
        if (widget.request.multiSelect && widget.request.options.isNotEmpty)
          LuminaButton(
            onPressed: _disabled || _selected.isEmpty
                ? null
                : () => _submit(
                    jsonEncode(
                      widget.request.options.where(_selected.contains).toList(),
                    ),
                  ),
            child: const Text('提交所选'),
          ),
        const SizedBox(height: LuminaSpacing.controlGap),
        Row(
          children: [
            Expanded(
              child: LuminaTextField(
                controller: _controller,
                enabled: !_disabled,
                hintText: '自定义回答',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: LuminaSpacing.controlGap),
            LuminaIconButton(
              onPressed: _disabled || _controller.text.trim().isEmpty
                  ? null
                  : () => _submit(_controller.text.trim()),
              icon: const LuminaIcon(LuminaIcons.send),
              tooltip: '提交回答',
            ),
          ],
        ),
        LuminaButton(
          onPressed: _disabled ? null : () => _submit('取消', cancel: true),
          child: const Text('取消'),
        ),
        if (_disabled) const Text('回答已提交，等待处理'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: LuminaTheme.of(context).colors.danger),
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
  bool get _disabled =>
      _sending || widget.store.actions.contains(widget.request.id);
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
      if (mounted) setState(() => _sending = false);
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
            onPressed: _disabled ? null : () => _submit(value.key),
            child: Text(value.value),
          ),
        ),
      if (_disabled) const Text('决定已提交，等待处理'),
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
