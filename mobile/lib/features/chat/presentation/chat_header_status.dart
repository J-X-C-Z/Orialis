import 'dart:async';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../data/agent_chat_service.dart';
import '../domain/agent_event_state.dart';
import 'agent_status_ring.dart';
import 'chat_activity_panel.dart';

({AgentRingStatus status, String label}) projectChatHeaderStatus({
  required AgentEventStore store,
  required int baselineRevision,
  required bool? presence,
  bool presenceFailed = false,
  bool sending = false,
  bool lastTurnFailed = false,
}) {
  if (presence == false) {
    return (status: AgentRingStatus.offline, label: '设备离线');
  }
  if (presenceFailed) {
    return (status: AgentRingStatus.unknown, label: '设备状态未知');
  }
  final fresh =
      store.runtimeRevision > baselineRevision && store.runtimeAttributed;
  if (fresh) {
    final status = store.agentStatus?.toLowerCase();
    if (const {
      'idle',
      'ready',
      'completed',
      'complete',
      'done',
      'cancelled',
      'canceled',
      'stopped',
    }.contains(status)) {
      return (status: AgentRingStatus.online, label: '助手已就绪');
    }
    if (status == 'failed' || status == 'error') {
      return (status: AgentRingStatus.error, label: '本轮处理失败');
    }
    if (status == 'waiting' ||
        status == 'queued' ||
        store.approvals.isNotEmpty ||
        store.clarifications.isNotEmpty) {
      return (status: AgentRingStatus.waiting, label: '等待处理或确认');
    }
    if (store.typing ||
        const {
          'thinking',
          'reasoning',
          'running',
          'working',
          'processing',
          'busy',
          'responding',
          'generating',
          'streaming',
          'typing',
        }.contains(status)) {
      return (status: AgentRingStatus.answering, label: '助手正在回复');
    }
  }
  if (sending) return (status: AgentRingStatus.waiting, label: '正在提交，等待助手');
  if (!fresh && lastTurnFailed) {
    return (status: AgentRingStatus.error, label: '本轮发送或处理失败');
  }
  return presence == true
      ? (status: AgentRingStatus.online, label: '设备在线 · 暂无实时状态')
      : (status: AgentRingStatus.unknown, label: '设备状态未知');
}

class ChatHeaderStatus extends StatefulWidget {
  const ChatHeaderStatus({
    required this.store,
    required this.agents,
    required this.deviceId,
    this.onRefresh,
    this.onSessionAction,
    this.sending = false,
    this.lastTurnFailed = false,
    super.key,
  });
  final AgentEventStore store;
  final AgentChatService agents;
  final String? deviceId;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(String)? onSessionAction;
  final bool sending, lastTurnFailed;

  @override
  State<ChatHeaderStatus> createState() => _ChatHeaderStatusState();
}

class _ChatHeaderStatusState extends State<ChatHeaderStatus>
    with WidgetsBindingObserver {
  final _changes = ValueNotifier<int>(0);
  Timer? _poll;
  Future<void>? _pending;
  late int _baseline, _devicesRevision;
  int _generation = 0;
  bool? _presence;
  bool _presenceFailed = false, _foreground = true, _visible = false;
  bool _revoked = false,
      _disposed = false,
      _sheetOpen = false,
      _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _baseline = widget.store.runtimeRevision;
    _devicesRevision = widget.store.agentDevicesChanged;
    widget.store.addListener(_storeChanged);
    _listenIdentity(widget.agents, true);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  void _listenIdentity(AgentChatService agents, bool add) {
    if (add) {
      agents.config.addIdentityListener(_identityRevoked);
      agents.config.addIdentityCommittedListener(_identityCommitted);
    } else {
      agents.config.removeIdentityListener(_identityRevoked);
      agents.config.removeIdentityCommittedListener(_identityCommitted);
    }
  }

  void _notify() {
    if (!_disposed && mounted) setState(() {});
    _changes.value++;
  }

  void _invalidate() {
    _generation++;
    _pending = null;
    _presence = null;
    _presenceFailed = false;
    _baseline = widget.store.runtimeRevision;
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _identityRevoked() async {
    _revoked = true;
    _invalidate();
    _notify();
  }

  Future<void> _identityCommitted() async {
    if (_disposed) return;
    _revoked = false;
    _updatePolling();
  }

  void _storeChanged() {
    final revision = widget.store.agentDevicesChanged;
    if (revision != _devicesRevision) {
      _devicesRevision = revision;
      if (_active) unawaited(_refreshPresence());
    }
    _notify();
  }

  bool get _active =>
      !_disposed && !_revoked && _foreground && (_visible || _sheetOpen);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      _updatePolling();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updatePolling();
  }

  void _updatePolling() {
    _poll?.cancel();
    _poll = null;
    if (!_active || widget.deviceId == null) {
      _generation++;
      _pending = null;
      return;
    }
    unawaited(_refreshPresence());
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_refreshPresence());
    });
  }

  @override
  void didUpdateWidget(ChatHeaderStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_storeChanged);
      widget.store.addListener(_storeChanged);
      _devicesRevision = widget.store.agentDevicesChanged;
    }
    if (oldWidget.agents != widget.agents) {
      _listenIdentity(oldWidget.agents, false);
      _listenIdentity(widget.agents, true);
    }
    if (oldWidget.deviceId != widget.deviceId ||
        oldWidget.agents != widget.agents ||
        oldWidget.store != widget.store) {
      _invalidate();
      _revoked = false;
      _updatePolling();
    }
    scheduleMicrotask(() {
      if (!_disposed) _changes.value++;
    });
  }

  Future<void> _refreshPresence() {
    if (!_active || widget.deviceId == null) return Future.value();
    if (_pending != null) return _pending!;
    final generation = ++_generation;
    return _pending = _probe(generation).whenComplete(() {
      if (generation == _generation) _pending = null;
    });
  }

  Future<void> _probe(int generation) async {
    final agents = widget.agents;
    final target = widget.deviceId!;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        widget.agents == agents &&
        widget.deviceId == target &&
        _active;
    try {
      final identity = await agents.identity();
      if (!current()) return;
      final presence = await agents.devicePresence(target);
      if (!current() || await agents.identity() != identity || !current()) {
        return;
      }
      _presence = presence;
      _presenceFailed = false;
    } on Object {
      if (!current()) return;
      _presence = null;
      _presenceFailed = true;
    }
    if (current()) _notify();
  }

  Future<void> _refresh() async {
    final agents = widget.agents;
    final target = widget.deviceId;
    final identity = await agents.identity();
    if (!_active || widget.agents != agents || widget.deviceId != target) {
      return;
    }
    final pending = _refreshPresence();
    final generation = _generation;
    await pending;
    if (!_active ||
        widget.agents != agents ||
        widget.deviceId != target ||
        generation != _generation ||
        await agents.identity() != identity ||
        generation != _generation ||
        widget.deviceId != target ||
        !_active) {
      return;
    }
    if (_presenceFailed) throw StateError('设备状态刷新失败');
    try {
      await widget.onRefresh?.call();
    } on Object {
      if (_active && generation == _generation && widget.deviceId == target) {
        _presence = null;
        _presenceFailed = true;
        _notify();
      }
      rethrow;
    }
  }

  Future<void> _sessionAction(String action) async {
    if (_disposed || _revoked || _actionBusy || widget.sending) return;
    _actionBusy = true;
    _notify();
    try {
      await widget.onSessionAction?.call(action);
    } on Object {
      if (!_disposed && _detailsContext?.mounted == true) {
        showLuminaMessage(_detailsContext!, '操作未完成，请重试');
      }
    } finally {
      _actionBusy = false;
      if (!_disposed) _notify();
    }
  }

  BuildContext? _detailsContext;
  Future<void> _showDetails() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await showLuminaSheet<void>(
        context: context,
        builder: (context) {
          _detailsContext = context;
          return ListenableBuilder(
            listenable: _changes,
            builder: (context, _) {
              if (_disposed || _revoked) return const Text('状态不可用，请重新打开会话');
              final projection = _projection;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '助手状态',
                    style: LuminaTheme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.agents.targetLabel(widget.deviceId) ??
                        widget.deviceId ??
                        '未选择设备',
                  ),
                  Text(
                    _presence == true
                        ? '设备在线'
                        : _presence == false
                        ? '设备离线'
                        : '设备状态未知',
                  ),
                  Text(projection.label),
                  if (_presenceFailed) const Text('设备状态刷新失败，可重新刷新'),
                  ChatActivityPanel(store: widget.store, onRefresh: _refresh),
                  if (widget.onSessionAction != null)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final action in const {
                          'session.stop': '停止',
                          'session.retry': '重试',
                          'session.reset': '重置',
                        }.entries)
                          LuminaButton(
                            primary: false,
                            onPressed: _actionBusy || widget.sending
                                ? null
                                : () => _sessionAction(action.key),
                            child: Text(action.value),
                          ),
                      ],
                    ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _sheetOpen = false;
      _detailsContext = null;
      if (_disposed) _changes.dispose();
    }
  }

  ({AgentRingStatus status, String label}) get _projection =>
      _revoked || widget.deviceId == null
      ? (status: AgentRingStatus.unknown, label: '设备状态未知')
      : projectChatHeaderStatus(
          store: widget.store,
          baselineRevision: _baseline,
          presence: _presence,
          presenceFailed: _presenceFailed,
          sending: widget.sending,
          lastTurnFailed: widget.lastTurnFailed,
        );

  @override
  Widget build(BuildContext context) {
    final projection = _projection;
    return AgentStatusRing(
      status: projection.status,
      label: '${projection.label}，查看详情',
      onPressed: _showDetails,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _poll?.cancel();
    widget.store.removeListener(_storeChanged);
    _listenIdentity(widget.agents, false);
    WidgetsBinding.instance.removeObserver(this);
    if (_sheetOpen) {
      scheduleMicrotask(() {
        if (_sheetOpen) _changes.value++;
      });
    } else {
      _changes.dispose();
    }
    super.dispose();
  }
}
