import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../core/attachments/attachment_bridge.dart';
import '../../core/realtime/mobile_realtime_client.dart';
import '../../core/sync/sync_engine.dart';
import '../../features/chat/data/chat_repository.dart';
import '../../features/chat/data/recent_hermes_models.dart';
import '../../features/chat/data/agent_chat_service.dart';
import '../../features/chat/application/chat_controller.dart';
import '../../features/chat/domain/agent_event_state.dart';
import '../../features/chat/domain/hermes_shortcuts.dart';
import '../../features/chat/presentation/agent_event_cards.dart';
import '../../features/chat/presentation/message_action_panel.dart';
import '../../features/chat/presentation/safe_markdown.dart';

final agentChatServiceProvider = Provider<AgentChatService>((ref) {
  final service = AgentChatService(ref.watch(appConfigProvider));
  ref.onDispose(service.dispose);
  return service;
});

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    required this.repository,
    this.conversationId = 'default',
    this.messageId,
    super.key,
  });

  final ChatRepository repository;
  final String conversationId;
  final String? messageId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _composerFocus = FocusNode();
  Message? _replyMessage;
  int _historyStart = 0;
  String? _highlightMessageId;
  String? _pendingNotificationMessageId;
  StreamSubscription<List<Conversation>>? _notificationConversationSubscription;
  Timer? _conversationPositionTimer;
  final _scrollController = ScrollController();
  late final _conversationsStream = widget.repository
      .watchConversations()
      .asyncMap((conversations) async {
        final service = ref.read(agentChatServiceProvider);
        final visible = await Future.wait(
          conversations.map((conversation) async {
            try {
              final target = await service.target(conversation.id);
              return service.isAllowedTarget(target) ? conversation : null;
            } catch (_) {
              return null;
            }
          }),
        );
        // Keep historical test/Codex records in storage, but close their UI.
        return visible.whereType<Conversation>().toList();
      });
  final _latestMessageAnchor = GlobalKey();
  final _imagePicker = ImagePicker();
  final _attachmentBridge = AttachmentBridge();
  final List<AttachmentRecord> _attachments = [];
  final Map<String, AgentEventStore> _conversationEvents = {};
  final _recentModels = RecentHermesModels();
  final Map<String, Completer<CommandResult?>> _commandWaiters = {};
  final Map<String, String> _pendingModelSwitches = {};
  final Map<String, String> _reasoningByConversation = {};
  AgentEventStore get _agentEvents =>
      _conversationEvents.putIfAbsent(_conversationId, AgentEventStore.new);
  late final StreamSubscription<MobileEnvelope> _realtimeSubscription;
  late String _conversationId;
  late final ChatController _chatController;
  bool _sending = false;
  bool _deliveryEnabled = false;
  bool _showingConversation = false;
  bool _hasOpenedConversation = false;
  String _conversationTitle = '主会话';
  String? _chatDeviceId;
  bool _startingDeviceChat = false;
  bool _approvalSheetOpen = false;
  bool _followLatest = true, _hasNewMessages = false, _scrollScheduled = false;
  bool _userDragging = false;
  bool _imeAdjusting = false;
  bool _imeAdjustmentScheduled = false;
  double _lastImeInset = 0;
  bool _positioningLatest = true;
  int _alignRetries = 0;
  String? _messageSignature;
  final Set<String> _failedMessages = {};

  // Realtime deltas arrive in bursts. Apply them all and rebuild at most once
  // per display frame so token bursts do not rebuild the transcript repeatedly.
  final List<MobileEnvelope> _pendingAgentEvents = [];
  bool _agentFlushScheduled = false;
  bool _chromeDirty = false;

  static const double _bottomThreshold = 72;
  static const _terminalKinds = {
    'stream.complete',
    'agent.complete',
    'stream.error',
    'agent.error',
  };

  bool get _nearBottom {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.extentAfter < _bottomThreshold;
  }

  void _syncFollowFromPosition() {
    final nearBottom = _nearBottom;
    if (nearBottom == _followLatest) {
      if (nearBottom && _hasNewMessages) {
        setState(() => _hasNewMessages = false);
      }
      return;
    }
    setState(() {
      _followLatest = nearBottom;
      if (nearBottom) _hasNewMessages = false;
    });
  }

  void _onScroll() {
    // While the finger is down, leaving the bottom must cancel follow right
    // away — otherwise a queued jump yanks the list back mid-drag.
    if (_userDragging) {
      if (_followLatest && !_nearBottom) {
        _followLatest = false;
      }
      return;
    }
    if (_imeAdjusting) return;
    _syncFollowFromPosition();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    if (inset == _lastImeInset) return;
    _lastImeInset = inset;
    _imeAdjusting = true;
    // A native keyboard animation can report several insets in one frame.
    // Follow the final layout once, preserving any intervening history drag.
    if (_imeAdjustmentScheduled) return;
    _imeAdjustmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imeAdjustmentScheduled = false;
      if (!mounted) return;
      if (_followLatest && !_userDragging && _scrollController.hasClients) {
        final position = _scrollController.position;
        if (position.extentAfter > .5) {
          _scrollController.jumpTo(position.maxScrollExtent);
        }
        _queueLatest();
      }
      _imeAdjusting = false;
    });
  }

  void _queueLatest() {
    if (_scrollScheduled ||
        !_showingConversation ||
        !_followLatest ||
        _userDragging) {
      return;
    }
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_showingConversation || !_scrollController.hasClients) {
        return;
      }
      // Re-check intent every frame: the user may have scrolled or dragged
      // while this callback was queued.
      if (!_followLatest || _userDragging) return;
      final position = _scrollController.position;
      if (position.extentAfter > .5 && _alignRetries < 3) {
        _alignRetries++;
        _scrollController.jumpTo(position.maxScrollExtent);
        _queueLatest();
        return;
      }
      _alignRetries = 0;
      if (_positioningLatest) setState(() => _positioningLatest = false);
    });
  }

  void _contentArrived() {
    if (_followLatest && !_userDragging) {
      _queueLatest();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_followLatest && !_hasNewMessages) {
          setState(() => _hasNewMessages = true);
        }
      });
    }
  }

  void _enqueueAgentEvent(MobileEnvelope event) {
    _pendingAgentEvents.add(event);
    if (_agentFlushScheduled) return;
    _agentFlushScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) => _flushAgentEvents());
  }

  void _flushAgentEvents() {
    _agentFlushScheduled = false;
    if (!mounted || _pendingAgentEvents.isEmpty) return;
    final batch = List<MobileEnvelope>.of(_pendingAgentEvents);
    _pendingAgentEvents.clear();

    var chromeDirty = _chromeDirty;
    _chromeDirty = false;
    var touchedCurrent = false;
    var needsApproval = false;
    final touchedStores = <AgentEventStore>{};

    for (final event in batch) {
      final resolved = resolveAgentEnvelope(event);
      final target = resolved.conversationId ?? _conversationId;
      final store = _conversationEvents.putIfAbsent(
        target,
        AgentEventStore.new,
      );
      final kind = resolved.kind;
      store.applySilent(event);
      if (kind == 'hermes.command.result') {
        for (final id in {
          ..._commandWaiters.keys,
          ..._pendingModelSwitches.keys,
        }) {
          final result = store.commandResults[id];
          if (result == null) continue;
          final waiter = _commandWaiters.remove(id);
          if (waiter != null && !waiter.isCompleted) waiter.complete(result);
          final selectedModel = _pendingModelSwitches.remove(id);
          if (selectedModel != null && _modelSwitchConfirmed(result)) {
            unawaited(_recentModels.recordSuccessfulSwitch(selectedModel));
          }
        }
      }
      touchedStores.add(store);
      if (_terminalKinds.contains(kind)) {
        store.typing = false;
        store.agentStatus = 'completed';
        chromeDirty = true;
      } else if (kind != 'stream.delta' && kind != 'agent.delta') {
        // Structural events (tools, approvals, status) move the action bar.
        chromeDirty = true;
      }
      if (kind == 'approval.request' || kind == 'clarify.request') {
        needsApproval = true;
      }
      if (target == _conversationId && _showingConversation) {
        touchedCurrent = true;
      }
    }

    for (final store in touchedStores) {
      store.notify();
    }
    if (chromeDirty) setState(() {});
    if (touchedCurrent && _showingConversation) _contentArrived();
    if (needsApproval) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _presentApproval());
    }
  }

  void _closeConversation() {
    FocusScope.of(context).unfocus();
    const LuminaConversationVisibility(false).dispatch(context);
    setState(() => _showingConversation = false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _conversationId = widget.conversationId;
    _highlightMessageId = widget.messageId;
    _chatController = ChatController(
      repository: widget.repository,
      flush: () async {
        final state = await ref.read(syncCoordinatorProvider).requestSync();
        if (state == SyncState.error || state == SyncState.authRequired) {
          throw StateError('消息未能上传');
        }
      },
    );
    final realtime = ref.read(realtimeClientProvider);
    _realtimeSubscription = realtime.events.listen((event) {
      if (event.type == 'message') return;
      if (!mounted) return;
      _enqueueAgentEvent(event);
    });
    _openNotificationRoute();
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.messageId != widget.messageId) {
      _openNotificationRoute();
    }
  }

  void _openNotificationRoute() {
    unawaited(_notificationConversationSubscription?.cancel());
    _notificationConversationSubscription = null;
    final messageId = widget.messageId;
    if (messageId == null || messageId.isEmpty) return;
    final conversationId = widget.conversationId;
    _notificationConversationSubscription = widget.repository
        .watchConversations()
        .listen((conversations) async {
          final conversation = conversations
              .where((item) => item.id == conversationId)
              .firstOrNull;
          if (conversation == null) return;
          final service = ref.read(agentChatServiceProvider);
          String? target;
          try {
            target = await service.target(conversationId);
          } catch (_) {
            return;
          }
          if (!mounted ||
              widget.conversationId != conversationId ||
              widget.messageId != messageId ||
              !service.isAllowedTarget(target)) {
            return;
          }
          unawaited(_notificationConversationSubscription?.cancel());
          _notificationConversationSubscription = null;
          await _openConversation(conversation);
          if (!mounted ||
              widget.conversationId != conversationId ||
              widget.messageId != messageId) {
            return;
          }
          setState(() {
            _highlightMessageId = messageId;
            _pendingNotificationMessageId = messageId;
            _followLatest = false;
            _positioningLatest = false;
          });
        });
  }

  @override
  void dispose() {
    _conversationPositionTimer?.cancel();
    unawaited(_notificationConversationSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    for (final waiter in _commandWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _commandWaiters.clear();
    _composerFocus.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _realtimeSubscription.cancel();
    super.dispose();
  }

  Future<void> _loadChatTarget(String conversationId) async {
    try {
      final target = await ref
          .read(agentChatServiceProvider)
          .target(conversationId);
      if (mounted && _conversationId == conversationId) {
        setState(() => _chatDeviceId = target);
      }
    } catch (_) {
      // Legacy/local conversations stay usable when the binding API is unavailable.
    }
  }

  Future<void> _chooseChatDevice() async {
    if (_startingDeviceChat || _sending) return;
    if (_controller.text.isNotEmpty ||
        _attachments.isNotEmpty ||
        _replyMessage != null) {
      showLuminaToast(context, '当前草稿已保留，请先发送或清空，再新建设备对话。');
      return;
    }
    setState(() => _startingDeviceChat = true);
    try {
      final service = ref.read(agentChatServiceProvider);
      var devices = await service.devices();
      if (!mounted) return;
      final device = await showLuminaSheet<ChatAgentDevice>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, updateDevices) => SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('与设备对话'),
                    const SizedBox(height: 12),
                    if (devices.isEmpty)
                      const Text('请在 Mac 或 Azure 服务器启动 Hermes 网关。'),
                    for (final device in devices)
                      OrialisListRow(
                        title: device.label,
                        subtitle: '${device.online ? "在线" : "离线"} · Hermes',
                        trailing: LuminaIconButton(
                          tooltip: '修改设备名称',
                          icon: const LuminaIcon(LuminaIcons.settings),
                          onPressed: () async {
                            final name = await _askChatName(
                              title: '修改设备名称',
                              initial: device.label,
                              hint: '设备名称（仅本机）',
                            );
                            if (name == null || !mounted) return;
                            try {
                              await service.renameDevice(device.id, name);
                              devices = await service.devices();
                              if (context.mounted) updateDevices(() {});
                              if (mounted) setState(() {});
                            } catch (_) {
                              if (mounted) {
                                showLuminaToast(this.context, '设备名称未能保存，请重试。');
                              }
                            }
                          },
                        ),
                        onTap: device.online
                            ? () => Navigator.of(
                                context,
                                rootNavigator: true,
                              ).pop(device)
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      if (device == null || !mounted) return;
      final remote = await service.createConversation(device);
      final conversation = await widget.repository.importDeviceConversation(
        remote,
      );
      if (!mounted) return;
      await _openConversation(conversation);
      if (mounted) setState(() => _chatDeviceId = device.id);
    } catch (_) {
      if (mounted) showLuminaToast(context, '设备对话未能建立。请确认已登录、服务器已更新且设备在线，再重试。');
    } finally {
      if (mounted) setState(() => _startingDeviceChat = false);
    }
  }

  bool get _hasHermesTarget =>
      ref.read(agentChatServiceProvider).isAllowedTarget(_chatDeviceId);

  String get _chatDeviceLabel =>
      ref.read(agentChatServiceProvider).targetLabel(_chatDeviceId) ?? '选择聊天设备';

  Future<bool> _requireHermesTarget() async {
    final conversationId = _conversationId;
    try {
      final service = ref.read(agentChatServiceProvider);
      final target = await service.target(conversationId, requireOnline: true);
      if (!mounted || _conversationId != conversationId) return false;
      setState(() => _chatDeviceId = target);
      if (_hasHermesTarget) return true;
    } catch (_) {
      if (!mounted) return false;
      showLuminaToast(context, '暂时无法确认 Hermes 设备，请联网后重试。');
      return false;
    }
    showLuminaToast(context, '请通过设备入口新建 Mac 或 Azure 的 Hermes 对话。');
    return false;
  }

  Future<void> _openConversation(Conversation conversation) async {
    setState(() {
      if (_conversationId != conversation.id) {
        _controller.clear();
        _attachments.clear();
        _replyMessage = null;
      }
      _historyStart = 0;
      _highlightMessageId = null;
      _conversationId = conversation.id;
      _conversationTitle = conversation.title;
      _chatDeviceId = null;
      _showingConversation = true;
      _hasOpenedConversation = true;
      _followLatest = true;
      _hasNewMessages = false;
      _messageSignature = null;
      _positioningLatest = true;
      _userDragging = false;
      _alignRetries = 0;
    });
    unawaited(_loadChatTarget(conversation.id));
    const LuminaConversationVisibility(true).dispatch(context);
    _queueLatest();
    // Safety valve: never leave the transcript blank if variable-height
    // bubbles keep revising the scroll extent.
    _conversationPositionTimer?.cancel();
    _conversationPositionTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted && _positioningLatest) {
        setState(() => _positioningLatest = false);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _presentApproval());
  }

  Future<void> _createConversation() async {
    await _chooseChatDevice();
  }

  Widget _conversationList() => OrialisPageScaffold(
    title: '聊天',
    subtitle: '想法在这里，慢慢成形。',
    actions: [
      LuminaIconButton(
        onPressed: _startingDeviceChat ? null : _chooseChatDevice,
        icon: const LuminaIcon(LuminaIcons.devices),
        tooltip: '与设备对话',
      ),
      LuminaIconButton(
        onPressed: _createConversation,
        icon: const LuminaIcon(LuminaIcons.add),
        tooltip: '新建会话',
      ),
    ],
    body: StreamBuilder<List<Conversation>>(
      stream: _conversationsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const OrialisEmptyState(text: '会话暂时无法加载，请稍后再试。');
        }
        if (!snapshot.hasData) return const Center(child: LuminaProgress());
        final conversations = snapshot.data!;
        if (conversations.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const OrialisEmptyState(
                  text: '从一个想法开始。\n新建会话，与 Orialis 一起整理。',
                  card: false,
                ),
                LuminaButton(
                  onPressed: _createConversation,
                  child: const Text('新建会话'),
                ),
              ],
            ),
          );
        }
        final pinnedCount = conversations.where((item) => item.pinned).length;
        return ReorderableList(
          padding: EdgeInsets.only(
            top: LuminaPageHeaderInset.of(context) + 12,
            bottom: MediaQuery.paddingOf(context).bottom + 24,
          ),
          itemCount: conversations.length,
          onReorderItem: (oldIndex, newIndex) async {
            if (oldIndex >= pinnedCount || newIndex >= pinnedCount) return;
            final ids = conversations
                .take(pinnedCount)
                .map((item) => item.id)
                .toList();
            ids.insert(newIndex, ids.removeAt(oldIndex));
            try {
              await widget.repository.reorderPinnedConversations(ids);
            } on Object {
              if (context.mounted) showLuminaToast(context, '排序未能保存，请重试');
            }
          },
          itemBuilder: (context, index) {
            final conversation = conversations[index];
            final latest = ref
                .watch(
                  chatLatestMessageProvider((
                    repository: widget.repository,
                    conversationId: conversation.id,
                  )),
                )
                .value;
            final preview = latest?.content.replaceAll('\n', ' ').trim();
            final row = OrialisListRow(
              title: conversation.pinned
                  ? '置顶 · ${conversation.title}'
                  : conversation.title,
              subtitle: preview != null && preview.isNotEmpty
                  ? (preview.length > 48
                        ? '${preview.substring(0, 48)}…'
                        : preview)
                  : conversation.type == 'main'
                  ? '主会话 · 随时开始新的想法'
                  : '轻触继续对话',
              leading: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: LuminaTheme.of(context).colors.accentSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: LuminaIcon(
                  conversation.type == 'main'
                      ? LuminaIcons.sparkles
                      : LuminaIcons.chat,
                  color: LuminaTheme.of(context).colors.accent,
                ),
              ),
              onTap: () => _openConversation(conversation),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (latest != null)
                    Text(
                      _formatMessageTime(latest.createdAt),
                      style: LuminaTheme.of(context).textTheme.labelSmall,
                    ),
                  LuminaIconButton(
                    tooltip: '会话选项',
                    icon: const LuminaIcon(LuminaIcons.more),
                    onPressed: () => _conversationOptions(conversation),
                  ),
                ],
              ),
            );
            return Padding(
              key: ValueKey(conversation.id),
              padding: const EdgeInsets.only(bottom: 8),
              child: conversation.pinned
                  ? ReorderableDelayedDragStartListener(
                      index: index,
                      child: row,
                    )
                  : row,
            );
          },
        );
      },
    ),
  );

  Future<void> _conversationOptions(Conversation conversation) async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => LuminaStack(
        mainAxisSize: MainAxisSize.min,
        children: [
          OrialisListRow(
            title: conversation.pinned ? '取消置顶' : '置顶会话',
            subtitle: '置顶后可长按拖动排序',
            onTap: () => Navigator.of(context, rootNavigator: true).pop('pin'),
          ),
          OrialisListRow(
            title: '恢复默认顺序',
            subtitle: '置顶状态保留，按最近更新排序',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('resetOrder'),
          ),
          OrialisListRow(
            title: '修改会话名称',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('rename'),
          ),
          const SizedBox(height: 8),
          if (conversation.type != 'main' && conversation.id != 'default')
            OrialisListRow(
              title: '删除会话',
              subtitle: '仅删除此普通会话',
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('delete'),
            ),
        ],
      ),
    );
    if (action == 'pin') {
      await widget.repository.setPinned(conversation, !conversation.pinned);
    }
    if (action == 'resetOrder') {
      await widget.repository.resetConversationOrder();
    }
    if (action == 'rename' && mounted) await _renameConversation(conversation);
    if (action == 'delete' && mounted) {
      final confirmed = await showLuminaDialog<bool>(
        context: context,
        title: '删除会话？',
        content: Text('“${conversation.title}”将被删除。'),
        actions: [
          LuminaButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            primary: false,
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('删除'),
          ),
        ],
      );
      if (confirmed == true) {
        await widget.repository.deleteConversation(conversation);
      }
    }
  }

  Future<String?> _askChatName({
    required String title,
    required String initial,
    required String hint,
  }) async {
    final controller = TextEditingController(text: initial);
    final name = await showLuminaDialog<String>(
      context: context,
      title: title,
      content: LuminaTextField(
        controller: controller,
        autofocus: true,
        hintText: hint,
      ),
      actions: [
        LuminaButton(
          primary: false,
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('取消'),
        ),
        LuminaButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isEmpty || value.length > 60) {
              showLuminaToast(context, '名称须为 1–60 个字符。');
              return;
            }
            Navigator.of(context, rootNavigator: true).pop(value);
          },
          child: const Text('保存'),
        ),
      ],
    );
    controller.dispose();
    return name;
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final title = await _askChatName(
      title: '修改会话名称',
      initial: conversation.title,
      hint: '会话名称',
    );
    if (title == null) return;
    await widget.repository.renameConversation(conversation, title);
    if (mounted && conversation.id == _conversationId) {
      setState(() => _conversationTitle = title);
    }
    unawaited(ref.read(syncCoordinatorProvider).requestSync());
  }

  Future<void> _sendAgentAction(
    String type,
    String requestId,
    Map<String, dynamic> payload,
  ) async {
    if (!await _requireHermesTarget()) {
      _agentEvents.actions.release(requestId);
      throw StateError('未绑定 Hermes 设备');
    }
    try {
      await ref
          .read(realtimeClientProvider)
          .sendEvent(
            kind: type,
            requestId: requestId,
            payload: {'conversationId': _conversationId, ...payload},
          );
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        _agentEvents.actions.release(requestId);
        showLuminaToast(context, '操作暂时无法发送：$error');
      }
      rethrow;
    }
  }

  Future<void> _runSessionAction(String type) async {
    if (_sending) return;
    if ((type == 'session.reset' || type == 'session.create') &&
        !await _confirmContextReset()) {
      return;
    }
    if (!mounted) return;
    setState(() => _sending = true);
    try {
      await _sendAgentAction(type, _requestId(), const {});
    } on Object {
      // Toast already surfaced by _sendAgentAction.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _requestId() => const Uuid().v7();

  Future<void> _showHermesCommand({String initialCommand = ''}) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => _CommandComposer(
        initialCommand: initialCommand,
        onSend: (command) async {
          final sent = await _sendHermesCommand(command);
          if (sent && context.mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
        },
      ),
    );
  }

  Future<void> _showDeliveryControls() async {
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => LuminaStack(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '主动投递',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Text(
              _deliveryEnabled
                  ? '已允许 Agent 将重要结果推送到此设备'
                  : '允许 Agent 将重要结果推送到此设备',
            ),
            const SizedBox(height: 16),
            LuminaButton(
              onPressed: () async {
                final previous = _deliveryEnabled;
                final enabled = !previous;
                setSheetState(() => _deliveryEnabled = enabled);
                setState(() => _deliveryEnabled = enabled);
                try {
                  await _sendAgentAction(
                    'delivery.notification',
                    _requestId(),
                    {'enabled': enabled},
                  );
                } catch (_) {
                  if (mounted) setState(() => _deliveryEnabled = previous);
                  if (context.mounted) {
                    setSheetState(() => _deliveryEnabled = previous);
                  }
                }
              },
              child: Text(_deliveryEnabled ? '关闭投递' : '允许投递'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSessionControls() async {
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => _SessionControls(
        onAction: (type, payload) async {
          if ((type == 'session.reset' || type == 'session.create') &&
              !await _confirmContextReset()) {
            return false;
          }
          await _sendAgentAction(type, _requestId(), {
            'sessionId': _conversationId,
            ...payload,
          });
          return true;
        },
      ),
    );
  }

  void _replyTo(Message message) {
    setState(() => _replyMessage = message);
    _composerFocus.requestFocus();
  }

  String _quoteText(Message message) {
    final text = message.content.trim();
    final attachmentNames = _decodeAttachments(
      message.attachmentsJson,
    ).map((item) => item['name'] as String? ?? '附件').join('、');
    final quote = [
      if (text.isNotEmpty) text,
      if (attachmentNames.isNotEmpty) '附件：$attachmentNames（仅引用名称）',
    ].join('\n');
    return quote.runes.length <= 2000
        ? quote
        : '${String.fromCharCodes(quote.runes.take(1999))}…';
  }

  Future<void> _messageOptions(BuildContext anchor, Message message) =>
      showChatMessageActionPanel(
        context: anchor,
        onReply: () => _replyTo(message),
        onCopy: () async {
          await Clipboard.setData(ClipboardData(text: message.content));
          if (mounted) showLuminaToast(context, '已复制');
        },
        onSelectText: () {
          unawaited(
            showLuminaSheet<void>(
              context: context,
              builder: (_) => LuminaSelectableText(message.content),
            ),
          );
        },
        onExplain: () {
          _replyTo(message);
          _fillPrompt('请解释这条引用消息的含义和关键点。');
        },
      );

  void _jumpToQuotedMessage(String? id, List<Message> messages) {
    final index = messages.indexWhere((item) => item.id == id);
    if (index < 0) {
      showLuminaToast(context, '原消息暂不可用，引用快照仍保留。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _followLatest = false;
      _positioningLatest = false;
      _historyStart = index;
      _highlightMessageId = id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  void _fillPrompt(String prompt) {
    // Keep a draft intact when adding a shortcut.
    final prefix = _controller.text.trim();
    _controller.text = prefix.isEmpty ? prompt : '$prefix\n$prompt';
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _composerFocus.requestFocus();
  }

  Future<bool> _confirmContextReset() async =>
      await showLuminaDialog<bool>(
        context: context,
        title: '重置 Hermes 上下文？',
        content: const Text('Hermes 将从新的上下文开始。App 中的历史消息仍然保留。'),
        actions: [
          LuminaButton(
            primary: false,
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('重置上下文'),
          ),
        ],
      ) ==
      true;

  Future<bool> _sendHermesCommand(String command) async {
    final name = command
        .trim()
        .split(RegExp(r'\s+'))
        .first
        .toLowerCase()
        .replaceFirst(RegExp(r'^/'), '');
    if ((name == 'new' || name == 'reset') && !await _confirmContextReset()) {
      return false;
    }
    if (!mounted) return false;
    await _sendAgentAction('hermes.command', _requestId(), {
      'command': command,
    });
    return true;
  }

  Future<CommandResult?> _sendTrackedCommand(
    String command, {
    String? selectedModel,
  }) async {
    final id = _requestId();
    final waiter = Completer<CommandResult?>();
    _commandWaiters[id] = waiter;
    if (selectedModel != null) _pendingModelSwitches[id] = selectedModel;
    try {
      await _sendAgentAction('hermes.command', id, {'command': command});
      return await waiter.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      if (mounted) showLuminaToast(context, '指令已发送，等待 Hermes 回复');
      return null;
    } on Object {
      _pendingModelSwitches.remove(id);
      return null;
    } finally {
      _commandWaiters.remove(id);
    }
  }

  bool _modelSwitchConfirmed(CommandResult result) =>
      result.ok &&
      (result.output.trimLeft().startsWith('Model switched to `') ||
          result.output.trimLeft().startsWith('已切换模型为 `'));

  bool _reasoningConfirmed(CommandResult result, String level) =>
      result.ok &&
      (result.output.contains('Reasoning effort set to `$level`') ||
          result.output.contains('推理强度已设置为 `$level`') ||
          (level == 'reset' &&
              (result.output.contains('reasoning override cleared') ||
                  result.output.contains('已清除本会话的推理覆盖'))));

  Future<void> _showModelSettings() async {
    final recent = _recentModels.load();
    if (!mounted) return;
    final conversationId = _conversationId;
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => _ModelSettingsSheet(
        recentModels: recent,
        initialReasoning: _reasoningByConversation[conversationId],
        onModel: (model) async {
          final result = await _sendTrackedCommand(
            '/model $model',
            selectedModel: model,
          );
          return result != null && _modelSwitchConfirmed(result);
        },
        onReasoning: (level) async {
          final result = await _sendTrackedCommand('/reasoning $level');
          final confirmed =
              result != null && _reasoningConfirmed(result, level);
          if (confirmed) {
            _reasoningByConversation[conversationId] = level;
          }
          return confirmed;
        },
      ),
    );
  }

  Future<void> _showAddMenu() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => LuminaStack(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrialisListRow(
            title: '拍照',
            leading: const LuminaIcon(LuminaIcons.camera),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('camera'),
          ),
          OrialisListRow(
            title: '选择照片',
            leading: const LuminaIcon(LuminaIcons.image),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('photos'),
          ),
          OrialisListRow(
            title: '选择文件',
            leading: const LuminaIcon(LuminaIcons.attachment),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('files'),
          ),
          OrialisListRow(
            title: '指令',
            leading: const LuminaIcon(LuminaIcons.terminal),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('commands'),
          ),
          OrialisListRow(
            title: '快捷提问',
            leading: const LuminaIcon(LuminaIcons.sparkles),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('prompts'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'camera' || 'photos' || 'files':
        await _pickAttachment(action);
      case 'commands':
        await _showCommandMenu();
      case 'prompts':
        await _showPromptMenu();
    }
  }

  Future<void> _showCommandMenu() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => LuminaStack(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('常用指令', style: LuminaTheme.of(context).textTheme.titleMedium),
          for (var i = 0; i < hermesShortcuts.length; i++)
            OrialisListRow(
              title: hermesShortcuts[i].title,
              subtitle: hermesShortcuts[i].description,
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('command:$i'),
            ),
          OrialisListRow(
            title: '重置上下文',
            subtitle: '开始新的 Hermes 上下文，保留 App 历史',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('reset'),
          ),
          OrialisListRow(
            title: '自定义命令',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('custom'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action.startsWith('command:')) {
      final shortcut = hermesShortcuts[int.parse(action.substring(8))];
      if (shortcut.command == '/model ') {
        await _showModelSettings();
      } else if (shortcut.editable) {
        await _showHermesCommand(initialCommand: shortcut.command);
      } else {
        try {
          await _sendHermesCommand(shortcut.command);
        } on Object {
          /* surfaced by sender */
        }
      }
      return;
    }
    switch (action) {
      case 'reset':
        await _runSessionAction('session.reset');
      case 'custom':
        await _showHermesCommand();
    }
  }

  Future<void> _showPromptMenu() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => LuminaStack(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('快捷提问', style: LuminaTheme.of(context).textTheme.titleMedium),
          OrialisListRow(
            title: '总结当前对话',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('summary'),
          ),
          OrialisListRow(
            title: '提取待办',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('tasks'),
          ),
          if (_replyMessage != null)
            OrialisListRow(
              title: '解释引用内容',
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('explain'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'summary':
        _fillPrompt('请总结当前对话的关键结论、已做决定和未解决的问题。');
      case 'tasks':
        _fillPrompt('请从当前对话中提取明确的待办事项，区分已确定和需要确认的内容。');
      case 'explain':
        _fillPrompt('请解释这条引用消息的含义和关键点。');
    }
  }

  Future<void> _pickAttachment(String action) async {
    if (action == 'camera' || action == 'photos') {
      final allowed = await showLuminaSheet<bool>(
        context: context,
        builder: (context) => LuminaStack(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              action == 'camera' ? '允许访问相机？' : '选择要分享的照片',
              style: LuminaTheme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              action == 'camera'
                  ? '用于拍摄并发送照片。继续后由系统确认访问权限。'
                  : '仅将你选择的照片加入当前消息。',
            ),
            const SizedBox(height: 20),
            LuminaButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('继续'),
            ),
            const SizedBox(height: 12),
            LuminaButton(
              primary: false,
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(false),
              child: const Text('暂不允许'),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
    }
    try {
      if (action == 'camera') {
        final photo = await _imagePicker.pickImage(source: ImageSource.camera);
        if (photo != null) await _addPaths([photo.path]);
      } else if (action == 'photos') {
        final photos = await _imagePicker.pickMultiImage(imageQuality: 90);
        await _addPaths(photos.map((photo) => photo.path));
      } else if (action == 'files') {
        // file_picker 13's pickFiles API is multi-select by definition.
        final result = await FilePicker.pickFiles();
        if (result.isNotEmpty) {
          await _addPaths(result.map((file) => file.path).whereType<String>());
        }
      }
    } catch (_) {
      if (mounted) showLuminaToast(context, '未能添加附件。请检查访问权限后重试。');
    }
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final additions = <AttachmentRecord>[];
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) throw StateError('附件文件已不可用');
        final size = await file.length();
        if (size == 0 || size > 20 * 1024 * 1024) {
          if (mounted) {
            showLuminaToast(context, '${path.split('/').last} 超过 20 MB 或为空');
          }
          continue;
        }
        additions.add(await _attachmentBridge.importFile(path));
      } catch (_) {
        if (mounted) {
          showLuminaToast(context, '${path.split('/').last} 未能添加，请重新选择。');
        }
      }
    }
    if (mounted && additions.isNotEmpty) {
      setState(() => _attachments.addAll(additions));
    }
  }

  Future<void> _send() async {
    if (_sending || (_controller.text.trim().isEmpty && _attachments.isEmpty)) {
      return;
    }
    setState(() => _sending = true);
    if (!await _requireHermesTarget()) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;
    final content = _controller.text;
    final attachments = List<AttachmentRecord>.from(_attachments);
    final reply = _replyMessage;
    final previousMessageId = _chatController.lastMessageId;
    _controller.clear();
    setState(() {
      _attachments.clear();
      _replyMessage = null;
    });
    _followLatest = true;
    _hasNewMessages = false;
    try {
      await _chatController.send(
        conversationId: _conversationId,
        content: content.trim(),
        replyToMessageId: reply?.id,
        replyQuote: reply == null ? null : _quoteText(reply),
        replyRole: reply?.role,
        attachmentsJson: jsonEncode(
          attachments.map((attachment) => attachment.toJson()).toList(),
        ),
      );
      if (mounted) {
        _queueLatest();
      }
    } catch (_) {
      if (mounted) {
        if (_chatController.lastMessageId == previousMessageId) {
          _controller.text = content;
          setState(() {
            _attachments.addAll(attachments);
            _replyMessage = reply;
          });
          showLuminaToast(context, '消息未能保存，内容已保留，请重试。');
        } else {
          _failedMessages.add(_chatController.lastMessageId!);
          showLuminaToast(context, '消息已保存在设备，联网后可重试发送。');
        }
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _retryMessage(String messageId) async {
    if (_sending) return;
    setState(() => _sending = true);
    if (!await _requireHermesTarget()) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _failedMessages.remove(messageId);
    });
    try {
      await _chatController.retry(messageId);
    } on Object catch (error) {
      if (mounted) {
        _failedMessages.add(messageId);
        showLuminaToast(context, '重试失败：$error');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String? get _currentAction {
    final runningTools = _agentEvents.tools.values.where(
      (item) => item.status == 'running',
    );
    if (runningTools.isNotEmpty) {
      return runningTools.last.detail ?? '正在${runningTools.last.name}';
    }
    if (_agentEvents.agentStatus != null &&
        !const {
          'completed',
          'idle',
          'done',
          'error',
          'stopped',
        }.contains(_agentEvents.agentStatus)) {
      return _agentEvents.agentStatusDetail ?? '正在整理你的请求';
    }
    if (_agentEvents.typing ||
        _agentEvents.streams.values.any((stream) => !stream.complete)) {
      return '正在组织回复';
    }
    return null;
  }

  /// `true` = turn fully unprocessed; `false` = partial tool run; `null` = healthy.
  /// Matches Hermes `turn_failure_copy` boundary notices that close a failed turn.
  bool? _lastFailedTurn(List<Message>? items) {
    if (items == null || items.isEmpty) return null;
    for (final message in items.reversed) {
      if (message.role != 'assistant') continue;
      final text = message.content.trim();
      if (text.isEmpty) continue;
      if (text.contains('Your request was not processed')) return true;
      if (text.contains('This turn did not complete')) return false;
      return null;
    }
    return null;
  }

  Future<void> _showChatOptions() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => LuminaStack(
        mainAxisSize: MainAxisSize.min,
        children: [
          OrialisListRow(
            title: '修改会话名称',
            leading: const LuminaIcon(LuminaIcons.settings),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('rename'),
          ),
          OrialisListRow(
            title: '模型与思考强度',
            leading: const LuminaIcon(LuminaIcons.sparkles),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('model'),
          ),
          OrialisListRow(
            title: 'Hermes 命令',
            leading: const LuminaIcon(LuminaIcons.terminal),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('command'),
          ),
          const SizedBox(height: 8),
          OrialisListRow(
            title: '主动投递',
            leading: const LuminaIcon(LuminaIcons.notification),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('delivery'),
          ),
          const SizedBox(height: 8),
          OrialisListRow(
            title: '会话控制',
            leading: const LuminaIcon(LuminaIcons.settings),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('session'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      final conversations = await widget.repository.watchConversations().first;
      final current = conversations.where((item) => item.id == _conversationId);
      if (mounted && current.isNotEmpty) {
        await _renameConversation(current.first);
      }
    }
    if (action == 'model') await _showModelSettings();
    if (action == 'command') await _showHermesCommand();
    if (action == 'delivery') await _showDeliveryControls();
    if (action == 'session') await _showSessionControls();
  }

  Future<void> _presentApproval() async {
    if (!mounted || _approvalSheetOpen || !_showingConversation) return;
    final pending = _agentEvents.approvals.values
        .where((item) => !_agentEvents.actions.contains(item.id))
        .toList();
    if (pending.isEmpty) return;
    _approvalSheetOpen = true;
    await showLuminaSheet<void>(
      context: context,
      builder: (sheetContext) => AgentApprovalSheet(
        request: pending.first,
        store: _agentEvents,
        onAction: (type, id, payload) async {
          await _sendAgentAction(type, id, payload);
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
      ),
    );
    _approvalSheetOpen = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => BackButtonListener(
    onBackButtonPressed: () async {
      if (!_showingConversation ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent == false ||
          Navigator.of(context, rootNavigator: true).canPop()) {
        return false;
      }
      if (View.of(context).viewInsets.bottom > 0) {
        FocusScope.of(context).unfocus();
      } else {
        _closeConversation();
      }
      return true;
    },
    child: PopScope(
      canPop: !_showingConversation,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !_showingConversation) return;
        if (View.of(context).viewInsets.bottom > 0) {
          FocusScope.of(context).unfocus();
        } else {
          _closeConversation();
        }
      },
      child: LuminaBranchTransition(
        index: _showingConversation ? 1 : 0,
        children: [
          _conversationList(),
          _hasOpenedConversation
              ? _conversationDetail(context)
              : const SizedBox.shrink(),
        ],
      ),
    ),
  );

  Widget _conversationDetail(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    final messages = ref.watch(
      chatMessagesProvider((
        repository: widget.repository,
        conversationId: _conversationId,
      )),
    );
    final action = _currentAction;
    final pendingApproval = _agentEvents.approvals.values.any(
      (item) => !_agentEvents.actions.contains(item.id),
    );
    const headerHeight = 64.0;
    final statusBanner = Builder(
      builder: (context) {
        final lastFailedTurn = _lastFailedTurn(messages.valueOrNull);
        final banner =
            action == null && !pendingApproval && lastFailedTurn == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: LuminaSurface(
                  radius: 12,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: lastFailedTurn != null
                      ? Row(
                          children: [
                            const LuminaIcon(LuminaIcons.warning, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                lastFailedTurn
                                    ? '本轮未处理完成，可重试或重置会话'
                                    : '上一轮部分执行，请确认后再继续',
                                style: LuminaTheme.of(
                                  context,
                                ).textTheme.bodySmall,
                              ),
                            ),
                            LuminaButton(
                              onPressed: _sending
                                  ? null
                                  : () => _runSessionAction('session.retry'),
                              child: const Text('重试'),
                            ),
                            const SizedBox(width: 8),
                            LuminaButton(
                              primary: false,
                              onPressed: _sending
                                  ? null
                                  : () => _runSessionAction('session.reset'),
                              child: const Text('重置'),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            const LuminaIcon(LuminaIcons.sparkles, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                pendingApproval ? '有一项操作等待你确认' : action!,
                                style: LuminaTheme.of(
                                  context,
                                ).textTheme.bodySmall,
                              ),
                            ),
                            if (!pendingApproval && action != null)
                              LuminaButton(
                                primary: false,
                                onPressed: _sending
                                    ? null
                                    : () => _runSessionAction('session.stop'),
                                child: const Text('停止'),
                              ),
                            if (pendingApproval)
                              LuminaButton(
                                onPressed: _presentApproval,
                                child: const Text('查看'),
                              ),
                          ],
                        ),
                ),
              );
        return LuminaResize(child: banner);
      },
    );
    return ColoredBox(
      color: colors.paper,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: messages.when(
                      loading: () => const Center(child: LuminaProgress()),
                      error: (error, _) => const OrialisEmptyState(
                        text: '消息暂时无法加载，请稍后再试。',
                        card: false,
                      ),
                      data: (items) {
                        final notificationMessage =
                            _pendingNotificationMessageId;
                        if (notificationMessage != null &&
                            items.any(
                              (item) => item.id == notificationMessage,
                            )) {
                          _pendingNotificationMessageId = null;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _jumpToQuotedMessage(notificationMessage, items);
                            }
                          });
                        }
                        // Identity + length + content hash detects a new final
                        // message without building a full-body signature string.
                        final last = items.isEmpty ? null : items.last;
                        final signature =
                            '$_conversationId:${items.length}:${last?.id ?? ''}:${last?.content.hashCode ?? 0}:${last?.attachmentsJson.hashCode ?? 0}';
                        if (_messageSignature != signature) {
                          _messageSignature = signature;
                          _contentArrived();
                        }
                        return items.isEmpty &&
                                _agentEvents.streams.isEmpty &&
                                !_agentEvents.typing
                            ? ListView(
                                padding: const EdgeInsets.only(
                                  top: headerHeight + 12,
                                ),
                                children: [
                                  statusBanner,
                                  const OrialisEmptyState(
                                    text: '从一句话开始。\n记录想法，或一起安排今天。',
                                    card: false,
                                  ),
                                ],
                              )
                            : NotificationListener<ScrollNotification>(
                                onNotification: (notification) {
                                  if (notification.depth != 0) return false;
                                  if (notification is ScrollStartNotification &&
                                      notification.dragDetails != null) {
                                    _userDragging = true;
                                  } else if (notification
                                      is ScrollEndNotification) {
                                    if (_userDragging) {
                                      _userDragging = false;
                                      _syncFollowFromPosition();
                                      if (_followLatest) _queueLatest();
                                    }
                                  } else if (notification
                                          is ScrollUpdateNotification &&
                                      _userDragging) {
                                    _onScroll();
                                  } else if (notification
                                          is ScrollMetricsNotification &&
                                      !_userDragging) {
                                    if (_followLatest) _queueLatest();
                                  }
                                  return false;
                                },
                                child: IgnorePointer(
                                  // Only the first paint is hidden while we jump to
                                  // the newest bubble; never trap the gesture.
                                  ignoring:
                                      _positioningLatest && _alignRetries < 3,
                                  child: Opacity(
                                    opacity: _positioningLatest ? 0 : 1,
                                    child: ListView.builder(
                                      key: ValueKey(_conversationId),
                                      controller: _scrollController,
                                      padding: const EdgeInsets.fromLTRB(
                                        20,
                                        headerHeight + 12,
                                        20,
                                        20,
                                      ),
                                      itemCount:
                                          items.length -
                                          _historyStart.clamp(0, items.length) +
                                          3 +
                                          (_historyStart > 0 ? 1 : 0),
                                      itemBuilder: (context, index) {
                                        if (index == 0) return statusBanner;
                                        index -= 1;
                                        final start = _historyStart.clamp(
                                          0,
                                          items.length,
                                        );
                                        if (start > 0 && index == 0) {
                                          return LuminaButton(
                                            primary: false,
                                            onPressed: () => setState(() {
                                              _historyStart = (start - 30)
                                                  .clamp(0, items.length);
                                            }),
                                            child: const Text('查看更早消息'),
                                          );
                                        }
                                        final messageIndex =
                                            index + start - (start > 0 ? 1 : 0);
                                        if (messageIndex < items.length) {
                                          final message = items[messageIndex];
                                          return Builder(
                                            builder: (messageContext) =>
                                                _ReplyGesture(
                                                  onReply: () =>
                                                      _replyTo(message),
                                                  onLongPress: () =>
                                                      _messageOptions(
                                                        messageContext,
                                                        message,
                                                      ),
                                                  child: _MessageBubble(
                                                    key: ValueKey(message.id),
                                                    message: message,
                                                    highlighted:
                                                        _highlightMessageId ==
                                                        message.id,
                                                    onQuoteTap: () =>
                                                        _jumpToQuotedMessage(
                                                          message
                                                              .replyToMessageId,
                                                          items,
                                                        ),
                                                    pluginReceived: _agentEvents
                                                        .receivedMessageIds
                                                        .contains(message.id),
                                                    failed: _failedMessages
                                                        .contains(message.id),
                                                    sending:
                                                        _sending &&
                                                        _chatController
                                                                .lastMessageId ==
                                                            message.id,
                                                    onRetry:
                                                        message.syncStatus ==
                                                            'pendingCreate'
                                                        ? () => _retryMessage(
                                                            message.id,
                                                          )
                                                        : null,
                                                  ),
                                                ),
                                          );
                                        }
                                        if (messageIndex == items.length) {
                                          return AgentEventsPanel(
                                            store: _agentEvents,
                                            onAction: _sendAgentAction,
                                          );
                                        }
                                        return SizedBox(
                                          key: _latestMessageAnchor,
                                          height: 1,
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              );
                      },
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: headerHeight,
                    child: OrialisTopBar(
                      title: _chatDeviceId == null
                          ? _conversationTitle
                          : '$_conversationTitle · $_chatDeviceLabel',
                      leading: LuminaIconButton(
                        onPressed: _closeConversation,
                        icon: const LuminaIcon(LuminaIcons.back),
                        tooltip: '返回会话列表',
                      ),
                      actions: [
                        LuminaIconButton(
                          onPressed: _startingDeviceChat || _sending
                              ? null
                              : _chooseChatDevice,
                          icon: const LuminaIcon(LuminaIcons.devices),
                          tooltip: _chatDeviceLabel,
                        ),
                        LuminaIconButton(
                          onPressed: _showChatOptions,
                          icon: const LuminaIcon(LuminaIcons.more),
                          tooltip: '更多会话操作',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_hasNewMessages)
              LuminaButton(
                onPressed: () {
                  setState(() {
                    _followLatest = true;
                    _hasNewMessages = false;
                  });
                  _queueLatest();
                },
                child: const Text('新消息 ↓'),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: LuminaSurface(
                radius: 24,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyMessage case final reply?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: LuminaQuotePreview(
                          title: reply.role == 'user' ? '回复自己' : '回复 Hermes',
                          text: _quoteText(reply),
                          onDismiss: () => setState(() => _replyMessage = null),
                        ),
                      ),
                    if (_attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (
                              var index = 0;
                              index < _attachments.length;
                              index++
                            )
                              LuminaButton(
                                primary: false,
                                onPressed: _sending
                                    ? null
                                    : () => setState(
                                        () => _attachments.removeAt(index),
                                      ),
                                icon: const LuminaIcon(
                                  LuminaIcons.close,
                                  size: 16,
                                ),
                                child: Text(
                                  _attachments[index].name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: LuminaTextField(
                            controller: _controller,
                            focusNode: _composerFocus,
                            minLines: 1,
                            maxLines: 4,
                            hintText: '写消息…',
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        LuminaIconButton(
                          onPressed: _sending ? null : _showAddMenu,
                          icon: const LuminaIcon(LuminaIcons.add),
                          tooltip: '附件与快捷指令',
                        ),
                        const SizedBox(width: 8),
                        LuminaIconButton(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const LuminaProgress()
                              : const LuminaIcon(LuminaIcons.send),
                          tooltip: '发送',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyGesture extends StatefulWidget {
  const _ReplyGesture({
    required this.child,
    required this.onReply,
    required this.onLongPress,
  });
  final Widget child;
  final VoidCallback onReply, onLongPress;

  @override
  State<_ReplyGesture> createState() => _ReplyGestureState();
}

class _ReplyGestureState extends State<_ReplyGesture> {
  double _distance = 0;

  @override
  Widget build(BuildContext context) => Semantics(
    customSemanticsActions: {
      const CustomSemanticsAction(label: '回复引用'): widget.onReply,
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.onLongPress,
      onHorizontalDragUpdate: (details) => setState(() {
        final direction = Directionality.of(context) == TextDirection.rtl
            ? -1
            : 1;
        _distance = (_distance + details.delta.dx * direction).clamp(0, 72);
      }),
      onHorizontalDragCancel: () => setState(() => _distance = 0),
      onHorizontalDragEnd: (_) {
        if (_distance >= 48) widget.onReply();
        setState(() => _distance = 0);
      },
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          if (_distance > 0)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 12),
              child: Text(
                '↩',
                style: TextStyle(color: LuminaTheme.of(context).colors.accent),
              ),
            ),
          Transform.translate(
            offset: Offset(
              _distance *
                  (Directionality.of(context) == TextDirection.rtl ? -1 : 1),
              0,
            ),
            child: widget.child,
          ),
        ],
      ),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.onQuoteTap,
    this.highlighted = false,
    this.pluginReceived = false,
    this.failed = false,
    this.sending = false,
  });
  final Message message;
  final VoidCallback? onRetry;
  final VoidCallback? onQuoteTap;
  final bool highlighted;
  final bool pluginReceived, failed, sending;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final attachments = _decodeAttachments(message.attachmentsJson);
    final pending = message.syncStatus != 'synced';
    final cloudConfirmed = !pending && message.remoteVersion > 0;
    final colors = LuminaTheme.of(context).colors;
    final status = !isUser
        ? ''
        : pluginReceived
        ? '✓'
        : cloudConfirmed
        ? '↑'
        : failed
        ? '!'
        : '◷';
    final statusLabel = !isUser
        ? ''
        : pluginReceived
        ? '插件已收到'
        : cloudConfirmed
        ? '已上传云端'
        : failed
        ? '发送失败，点击重试'
        : sending
        ? '发送中'
        : '等待上传';
    final metadata = Semantics(
      label: '${_formatMessageTime(message.createdAt)} $statusLabel',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_formatMessageTime(message.createdAt)}${sending && pending ? '' : '  $status'}',
            style: LuminaTheme.of(
              context,
            ).textTheme.labelSmall.copyWith(color: colors.muted, fontSize: 11),
          ),
          if (sending && pending)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: SizedBox(width: 12, height: 12, child: LuminaProgress()),
            ),
        ],
      ),
    );
    final inlineMetadata =
        isUser && !pending && attachments.isEmpty && message.content.isNotEmpty;
    // Isolate each bubble's paint so a long thread's scroll/repaint stays local.
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: highlighted ? colors.accentSoft : const Color(0x00000000),
          borderRadius: BorderRadius.circular(16),
        ),
        child: OrialisChatBubble(
          isUser: isUser,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.replyQuote case final quote?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LuminaQuotePreview(
                    title: message.replyRole == 'user' ? '自己' : 'Hermes',
                    text: quote,
                    onTap: onQuoteTap,
                  ),
                ),
              if (message.content.isNotEmpty)
                inlineMetadata
                    ? Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 8,
                        runSpacing: 4,
                        children: [Text(message.content), metadata],
                      )
                    : isUser
                    ? Text(message.content)
                    : SafeMarkdownView(source: message.content),
              for (final attachment in attachments)
                _AttachmentPreview(attachment: attachment),
              if (!inlineMetadata) ...[
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    metadata,
                    if (isUser && pending) ...[
                      Semantics(
                        button: true,
                        label: '重试发送',
                        child: LuminaTap(
                          behavior: HitTestBehavior.opaque,
                          onTap: sending ? null : onRetry,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 10,
                            ),
                            child: Text(
                              failed ? '重试' : '待发送 · 重试',
                              style: LuminaTheme.of(
                                context,
                              ).textTheme.labelSmall,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _formatMessageTime(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '';
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

List<Map<String, dynamic>> _decodeAttachments(String value) {
  try {
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  } on Object {
    return const [];
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  Widget build(BuildContext context) {
    final name = attachment['name'] as String? ?? '附件';
    final mimeType = attachment['mimeType'] as String? ?? '';
    final url = attachment['downloadUrl'] as String?;
    final isImage = mimeType.startsWith('image/') && url != null;
    return Container(
      margin: const EdgeInsets.only(top: AppChatMetrics.attachmentTopGap),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: LuminaTheme.of(context).colors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.attachment),
      ),
      child: isImage
          ? Image.network(
              url,
              width: AppChatMetrics.imageWidth,
              height: AppChatMetrics.imageHeight,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fileLabel(name, mimeType),
            )
          : _fileLabel(name, mimeType),
    );
  }

  Widget _fileLabel(String name, String mimeType) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.item),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LuminaIcon(
            mimeType.startsWith('image/')
                ? LuminaIcons.image
                : LuminaIcons.file,
          ),
          const SizedBox(width: AppSpacing.controlGap),
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _ModelSettingsSheet extends StatefulWidget {
  const _ModelSettingsSheet({
    required this.recentModels,
    required this.initialReasoning,
    required this.onModel,
    required this.onReasoning,
  });

  final Future<List<String>> recentModels;
  final String? initialReasoning;
  final Future<bool> Function(String model) onModel;
  final Future<bool> Function(String level) onReasoning;

  @override
  State<_ModelSettingsSheet> createState() => _ModelSettingsSheetState();
}

class _ModelSettingsSheetState extends State<_ModelSettingsSheet> {
  final _model = TextEditingController();
  List<String> _recent = [];
  late String? _reasoning = widget.initialReasoning;
  bool _busy = false;
  bool _advanced = false;
  String? _feedback;

  static const _commonLevels = <String, String>{
    'reset': '跟随默认',
    'none': '关闭',
    'low': '低',
    'medium': '中',
    'high': '高',
  };
  static const _advancedLevels = <String, String>{
    'minimal': '极低',
    'xhigh': '更高',
    'max': '最高',
    'ultra': 'Ultra',
  };

  @override
  void initState() {
    super.initState();
    widget.recentModels.then((models) {
      if (!mounted) return;
      setState(() {
        _recent = {
          ..._recent,
          ...models,
        }.take(RecentHermesModels.maxEntries).toList();
      });
    });
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _switchModel(String value) async {
    final model = value.trim();
    if (model.isEmpty || model.contains(RegExp(r'\s'))) {
      setState(() => _feedback = '请输入不含空格的模型名称');
      return;
    }
    if (_busy) return;
    _model.text = model;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    final confirmed = await widget.onModel(model);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _feedback = confirmed ? '已切换到 $model' : '尚未收到切换确认，请查看聊天中的指令结果';
      if (confirmed) {
        _recent = [
          model,
          ..._recent.where((item) => item != model),
        ].take(RecentHermesModels.maxEntries).toList();
      }
    });
  }

  Future<void> _setReasoning(String level) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    final confirmed = await widget.onReasoning(level);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _feedback = confirmed ? '当前会话已更新思考强度' : '尚未收到设置确认，请查看聊天中的指令结果';
      if (confirmed) _reasoning = level;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final query = _model.text.trim().toLowerCase();
    final suggestions = _recent
        .where((item) => query.isEmpty || item.toLowerCase().contains(query))
        .toList();
    return LuminaStack(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('模型与思考强度', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text('设置只作用于当前 Hermes 会话。', style: theme.textTheme.bodySmall),
        const SizedBox(height: 18),
        LuminaTextField(
          controller: _model,
          label: '切换模型',
          hintText: '输入模型名称，例如 provider/model',
          onChanged: (_) => setState(() {}),
          onSubmitted: _switchModel,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 10),
        LuminaButton(
          onPressed: _busy ? null : () => _switchModel(_model.text),
          child: const Text('切换模型'),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('最近使用', style: theme.textTheme.titleMedium),
          for (final model in suggestions)
            OrialisListRow(
              title: model,
              subtitle: '点击切换',
              onTap: _busy ? null : () => _switchModel(model),
            ),
        ],
        const SizedBox(height: 20),
        Text('思考强度', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('Hermes 会按当前模型能力执行；较高档位可能折算。', style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _commonLevels.entries)
              LuminaButton(
                primary: _reasoning == entry.key,
                onPressed: _busy ? null : () => _setReasoning(entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LuminaButton(
          primary: false,
          onPressed: () => setState(() => _advanced = !_advanced),
          child: Text(_advanced ? '收起更多强度' : '更多强度'),
        ),
        if (_advanced) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in _advancedLevels.entries)
                LuminaButton(
                  primary: _reasoning == entry.key,
                  onPressed: _busy ? null : () => _setReasoning(entry.key),
                  child: Text(entry.value),
                ),
            ],
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const Center(child: LuminaProgress()),
        ],
        if (_feedback != null) ...[
          const SizedBox(height: 12),
          Text(_feedback!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _CommandComposer extends StatefulWidget {
  const _CommandComposer({required this.onSend, this.initialCommand = ''});
  final String initialCommand;
  final Future<void> Function(String command) onSend;

  @override
  State<_CommandComposer> createState() => _CommandComposerState();
}

class _CommandComposerState extends State<_CommandComposer> {
  late final _controller = TextEditingController(text: widget.initialCommand);
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final command = _controller.text.trim();
    if (command.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(command);
    } on Object {
      // The parent has displayed the send failure; retain the command to retry.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.zero,
      child: LuminaStack(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Hermes 命令',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.controlGap),
          Row(
            children: [
              Expanded(
                child: LuminaTextField(
                  controller: _controller,
                  enabled: !_sending,
                  autofocus: true,
                  onSubmitted: (_) => _send(),
                  hintText: '输入要交给 Hermes 的命令',
                ),
              ),
              const SizedBox(width: AppSpacing.controlGap),
              LuminaIconButton(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: LuminaProgress(),
                      )
                    : const LuminaIcon(LuminaIcons.send),
                tooltip: '发送命令',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '指令结果显示在聊天中；模型名称和参数由当前 Hermes 决定。',
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class _SessionControls extends StatefulWidget {
  const _SessionControls({required this.onAction});
  final Future<bool> Function(String type, Map<String, dynamic> payload)
  onAction;

  @override
  State<_SessionControls> createState() => _SessionControlsState();
}

class _SessionControlsState extends State<_SessionControls> {
  final _titleController = TextEditingController();
  bool _sending = false;
  String? _lastResult;
  bool _lastOk = true;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _run(
    String type, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _lastResult = null;
    });
    try {
      if (!await widget.onAction(type, payload)) return;
      if (mounted) {
        setState(() {
          _lastOk = true;
          _lastResult = _successCopy(type);
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _lastOk = false;
          _lastResult = '操作未完成：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _successCopy(String type) => '请求已发送，执行结果见聊天时间线。';

  Future<void> _submitTitle() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _lastOk = false;
        _lastResult = '请先填写会话标题。';
      });
      return;
    }
    await _run('session.title', {'title': title});
    if (mounted && _lastOk) _titleController.clear();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.zero,
      child: LuminaStack(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('会话控制', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.controlGap),
          Text(
            '消息未处理或会话异常时，可先「重试」；仍不行再「重置」。',
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.controlGap),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              LuminaButton(
                onPressed: _sending ? null : () => _run('session.retry'),
                icon: const LuminaIcon(LuminaIcons.sync),
                child: const Text('重试'),
              ),
              LuminaButton(
                onPressed: _sending ? null : () => _run('session.stop'),
                icon: const LuminaIcon(LuminaIcons.close),
                child: const Text('停止'),
              ),
              LuminaButton(
                onPressed: _sending ? null : () => _run('session.reset'),
                icon: const LuminaIcon(LuminaIcons.branch),
                child: const Text('重置'),
              ),
              LuminaButton(
                onPressed: _sending ? null : () => _run('session.resume'),
                icon: const LuminaIcon(LuminaIcons.play),
                child: const Text('恢复'),
              ),
              LuminaButton(
                onPressed: _sending ? null : () => _run('session.status'),
                icon: const LuminaIcon(LuminaIcons.info),
                child: const Text('状态'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.controlGap),
          Row(
            children: [
              Expanded(
                child: LuminaTextField(
                  controller: _titleController,
                  enabled: !_sending,
                  hintText: '设置会话标题',
                ),
              ),
              const SizedBox(width: AppSpacing.controlGap),
              LuminaIconButton(
                onPressed: _sending ? null : _submitTitle,
                icon: const LuminaIcon(LuminaIcons.check),
                tooltip: '保存标题',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.controlGap),
          if (_sending) const LuminaProgress(),
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _lastResult!,
                style: TextStyle(
                  color: _lastOk
                      ? LuminaTheme.of(context).colors.ink
                      : LuminaTheme.of(context).colors.danger,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '会话事件有结果时会显示在聊天时间线中。',
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
