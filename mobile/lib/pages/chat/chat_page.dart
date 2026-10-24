import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/app.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaConversationVisibility, OrialisPageScaffold;

import '../../core/database/app_database.dart';
import '../../core/config/app_config.dart';
import '../../core/attachments/attachment_bridge.dart';
import '../../core/realtime/mobile_realtime_client.dart';
import '../../features/chat/data/chat_repository.dart';
import '../../features/chat/data/chat_drafts.dart';
import '../../features/chat/data/recent_hermes_models.dart';
import '../../features/chat/data/agent_chat_service.dart';
import '../../features/chat/data/workspace_client.dart';
import '../../features/chat/presentation/workspace_page.dart';
import '../../features/chat/presentation/chat_attachment.dart';
import '../../features/chat/application/chat_controller.dart';
import '../../features/chat/application/chat_share_coordinator.dart';
import '../../features/chat/domain/agent_event_state.dart';
import '../../features/chat/domain/hermes_shortcuts.dart';
import '../../features/chat/domain/session_summary.dart';
import '../../features/chat/domain/chat_transcript.dart';
import '../../features/chat/presentation/agent_event_cards.dart';
import '../../features/chat/presentation/chat_header_status.dart';
import '../../features/chat/presentation/chat_device_picker.dart';
import '../../features/chat/presentation/chat_thinking_indicator.dart';
import '../../features/chat/presentation/message_action_panel.dart';
import '../../features/chat/presentation/safe_markdown.dart';
import '../../features/chat/presentation/slash_command_suggestions.dart';

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
    this.shareId,
    super.key,
  });

  final ChatRepository repository;
  final String conversationId;
  final String? messageId;
  final String? shareId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _conversationSearch = TextEditingController();
  String? _conversationDeviceFilter;
  ChatSessionState? _conversationStateFilter;
  late final AppConfig _draftConfig;
  Future<ChatDrafts>? _drafts;
  Future<void>? _draftInitialization;
  bool _chatIdentityActive = true;
  int _draftRevision = 0;
  bool _changingDraft = false;
  bool _draftWarningShown = false;
  Timer? _draftSaveTimer;
  String _observedDraftText = '';
  String? _shareId;
  bool _importingShare = false;
  bool _shareImportFailed = false;
  final _appliedShareIds = <String>{};

  Future<void> _persistDraft() async {
    _draftSaveTimer?.cancel();
    final initialization = _draftInitialization;
    if (initialization != null) {
      await initialization;
      if (!mounted) return;
    }
    final store = _drafts;
    if (store == null || _changingDraft) return;
    final conversationId = _conversationId;
    final text = _controller.text;
    final state = ChatDraftState(
      text: text,
      attachments: List.of(_attachments),
      appliedShareIds: Set.of(_appliedShareIds),
    );
    try {
      await (await store).saveState(conversationId, state);
    } catch (_) {
      if (mounted && !_draftWarningShown) {
        _draftWarningShown = true;
        showLuminaToast(context, '草稿未能保存到设备，请勿关闭应用。');
      }
    }
  }

  void _draftChanged() {
    if (_changingDraft || _controller.text == _observedDraftText) return;
    _observedDraftText = _controller.text;
    _draftRevision++;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistDraft());
    });
  }

  Future<void> _restoreDraft() async {
    final store = _drafts;
    if (store == null) return;
    final revision = _draftRevision;
    final conversationId = _conversationId;
    try {
      final state = await (await store).loadState(conversationId);
      final text = state.text;
      if (!mounted ||
          store != _drafts ||
          revision != _draftRevision ||
          conversationId != _conversationId) {
        return;
      }
      _changingDraft = true;
      _observedDraftText = text;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _attachments
        ..clear()
        ..addAll(state.attachments);
      _appliedShareIds
        ..clear()
        ..addAll(state.appliedShareIds);
      _changingDraft = false;
      setState(() {});
    } catch (_) {
      // The composer remains usable when local preferences are unavailable.
    }
  }

  Future<void> _revokeDraftIdentity() async {
    _chatIdentityActive = false;
    _pendingAgentEvents.clear();
    _conversationEvents.clear();
    _chatDeviceId = null;
    for (final waiter in _commandWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _commandWaiters.clear();
    _pendingModelSwitches.clear();
    await _persistDraft();
    _drafts = null;
    _draftRevision++;
    _shareId = null;
    _attachments.clear();
    _appliedShareIds.clear();
    _changingDraft = true;
    _observedDraftText = '';
    _controller.clear();
    _changingDraft = false;
    if (mounted) setState(() {});
  }

  Future<void> _openDraftIdentity() async {
    _drafts = ChatDrafts.open(_draftConfig);
    final initialization = _restoreDraft();
    _draftInitialization = initialization;
    try {
      await initialization;
      if (_draftInitialization == initialization) _chatIdentityActive = true;
    } finally {
      if (_draftInitialization == initialization) _draftInitialization = null;
    }
  }

  final _composerFocus = FocusNode();
  Message? _replyMessage;
  int _historyStart = 0;
  int _historyLimit = 60;
  String? _highlightMessageId;
  String? _pendingNotificationMessageId;
  StreamSubscription<List<Conversation>>? _notificationConversationSubscription;
  Timer? _conversationPositionTimer;
  final _scrollController = ScrollController();
  final _conversationListController =
      StreamController<List<Conversation>>.broadcast();
  Stream<List<Conversation>> get _conversationsStream =>
      _conversationListController.stream;
  StreamSubscription<List<Conversation>>? _conversationListSubscription;
  StreamSubscription<(String, String?)>? _targetSubscription;
  List<Conversation> _localConversations = [];
  final Map<String, String?> _visibleTargets = {};
  List<Conversation>? _emittedConversations;
  Map<String, String?> _emittedTargets = {};
  int _listGeneration = 0;

  void _emitConversations() {
    if (!mounted) return;
    final conversations = _localConversations
        .where(
          (row) => ref
              .read(agentChatServiceProvider)
              .isAllowedTarget(_visibleTargets[row.id]),
        )
        .toList();
    final targets = {
      for (final row in conversations) row.id: _visibleTargets[row.id],
    };
    if (listEquals(conversations, _emittedConversations) &&
        mapEquals(targets, _emittedTargets)) {
      return;
    }
    _emittedConversations = conversations;
    _emittedTargets = targets;
    _conversationListController.add(conversations);
  }

  Future<void> _updateConversations(List<Conversation> rows) async {
    final generation = ++_listGeneration;
    _localConversations = rows;
    final service = ref.read(agentChatServiceProvider);
    final cached = await Future.wait(
      rows.map((row) async {
        try {
          return await service.cachedTarget(row.id);
        } catch (_) {
          return null;
        }
      }),
    );
    if (!mounted || generation != _listGeneration) return;
    _visibleTargets.clear();
    for (var i = 0; i < rows.length; i++) {
      _visibleTargets[rows[i].id] = cached[i];
    }
    _emitConversations();
    for (final row in rows) {
      unawaited(() async {
        String? target;
        try {
          target = await service.target(row.id);
        } catch (_) {
          target = null;
        }
        if (!mounted || generation != _listGeneration) return;
        _visibleTargets[row.id] = target;
        _emitConversations();
      }());
    }
  }

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
    if (!_showingConversation) return;
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
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _contentArrived() {
    if (!_showingConversation) return;
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
    if (!_chatIdentityActive) return;
    if (ChatRepository.isBackgroundChatConversationId(
      resolveAgentEnvelope(event).conversationId ?? '',
    )) {
      return;
    }
    _pendingAgentEvents.add(event);
    if (_agentFlushScheduled) return;
    _agentFlushScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) => _flushAgentEvents());
  }

  void _flushAgentEvents() {
    _agentFlushScheduled = false;
    if (!mounted || !_chatIdentityActive || _pendingAgentEvents.isEmpty) return;
    final batch = List<MobileEnvelope>.of(_pendingAgentEvents);
    _pendingAgentEvents.clear();

    var chromeDirty = _chromeDirty;
    _chromeDirty = false;
    var touchedCurrent = false;
    final touchedStores = <AgentEventStore>{};

    for (final event in batch) {
      final resolved = resolveAgentEnvelope(event);
      if (resolved.kind == 'workspace.response') continue;
      final requestId = event.requestId;
      final pendingOwner = requestId == null
          ? null
          : _conversationEvents.entries
                .where((entry) => entry.value.actions.contains(requestId))
                .firstOrNull
                ?.key;
      final target = resolved.conversationId ?? pendingOwner ?? _conversationId;
      final store = _conversationEvents.putIfAbsent(
        target,
        AgentEventStore.new,
      );
      final kind = resolved.kind;
      store.applySilent(
        event,
        attributed: resolved.conversationId != null || pendingOwner != null,
      );
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
        store.agentStatus = kind?.endsWith('error') == true
            ? 'failed'
            : 'completed';
        chromeDirty = true;
      } else if (kind != 'stream.delta' && kind != 'agent.delta') {
        // Structural events (tools, approvals, status) move the action bar.
        chromeDirty = true;
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
  }

  void _closeConversation() {
    unawaited(_persistDraft());
    FocusScope.of(context).unfocus();
    const LuminaConversationVisibility(false).dispatch(context);
    setState(() => _showingConversation = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_persistDraft());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _conversationId = widget.conversationId;
    _draftConfig = ref.read(appConfigProvider);
    _draftConfig.addIdentityListener(_revokeDraftIdentity);
    _draftConfig.addIdentityCommittedListener(_openDraftIdentity);
    _controller.addListener(_draftChanged);
    unawaited(_openDraftIdentity());
    _chatController = ChatController(
      repository: widget.repository,
      flush: ref.read(syncCoordinatorProvider).flushMessage,
    );
    final realtime = ref.read(realtimeClientProvider);
    _realtimeSubscription = realtime.events.listen((event) {
      if (event.type == 'message') return;
      if (!mounted) return;
      _enqueueAgentEvent(event);
    });
    _targetSubscription = ref
        .read(agentChatServiceProvider)
        .targetChanges
        .listen((change) {
          if (change.$1.isEmpty) {
            _listGeneration++;
            _visibleTargets.clear();
            if (mounted) setState(() => _chatDeviceId = null);
          } else {
            _visibleTargets[change.$1] = change.$2;
          }
          _emitConversations();
          if (mounted && change.$1 == _conversationId) {
            setState(() => _chatDeviceId = change.$2);
          }
        });
    _conversationListSubscription = widget.repository
        .watchChatConversations()
        .listen(
          _updateConversations,
          onError: (Object error, StackTrace stack) =>
              _conversationListController.addError(error, stack),
        );
    _openNotificationRoute();
    _prepareShare();
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.messageId != widget.messageId) {
      _openNotificationRoute();
    }
    if (oldWidget.shareId != widget.shareId) _prepareShare();
  }

  void _prepareShare() {
    final id = widget.shareId;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.shareId != id) return;
      final shares = ref.read(chatShareCoordinatorProvider);
      await shares?.open(id);
      if (!mounted || widget.shareId != id || shares?.pending?.id != id) return;
      unawaited(_persistDraft());
      setState(() {
        _shareId = id;
        _shareImportFailed = false;
        _showingConversation = false;
      });
      const LuminaConversationVisibility(false).dispatch(context);
    });
  }

  Future<void> _importSharedDraft() async {
    final id = _shareId;
    final shares = ref.read(chatShareCoordinatorProvider);
    if (id == null || shares == null || _importingShare) return;
    final conversationId = _conversationId;
    final drafts = _drafts;
    setState(() {
      _importingShare = true;
      _shareImportFailed = false;
    });
    try {
      final imported = await shares.importIntoDraft(
        id: id,
        alreadyApplied: _appliedShareIds.contains(id),
        importFile: _attachmentBridge.importFile,
        isCurrent: () =>
            mounted &&
            _conversationId == conversationId &&
            _drafts == drafts &&
            _shareId == id,
        apply: (payload, files, isCurrent) async {
          if (drafts == null || !isCurrent()) {
            throw StateError('Account changed');
          }
          // Persist first: failed storage must leave the native share retryable.
          late String text;
          late int revision;
          do {
            revision = _draftRevision;
            text = appendSharedText(_controller.text, payload.text);
            await (await drafts).saveState(
              conversationId,
              ChatDraftState(
                text: text,
                attachments: [..._attachments, ...files],
                appliedShareIds: {..._appliedShareIds, id},
              ),
            );
            if (!isCurrent()) throw StateError('Account changed');
          } while (_draftRevision != revision);
          setState(() {
            _controller.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
            _attachments.addAll(files);
            _appliedShareIds.add(id);
          });
        },
      );
      if (mounted && imported && _shareId == id) {
        setState(() => _shareId = null);
        showLuminaToast(context, '已加入草稿，确认后发送');
      }
    } catch (_) {
      if (mounted && _shareId == id) {
        setState(() => _shareImportFailed = true);
        showLuminaToast(context, '分享未能导入，请重试；原内容仍已保留。');
      }
    } finally {
      if (mounted) setState(() => _importingShare = false);
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
        });
  }

  @override
  void dispose() {
    unawaited(_persistDraft());
    _draftConfig.removeIdentityListener(_revokeDraftIdentity);
    _draftConfig.removeIdentityCommittedListener(_openDraftIdentity);
    _controller.removeListener(_draftChanged);
    _conversationPositionTimer?.cancel();
    unawaited(_notificationConversationSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    for (final waiter in _commandWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _commandWaiters.clear();
    _listGeneration++;
    unawaited(_conversationListSubscription?.cancel());
    unawaited(_targetSubscription?.cancel());
    unawaited(_conversationListController.close());
    _composerFocus.dispose();
    _controller.dispose();
    _conversationSearch.dispose();
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
      final device = await showLuminaSheet<ChatAgentDevice>(
        context: context,
        builder: (context) => ChatDevicePicker(
          agents: service,
          onRename: (device) async {
            final name = await _askChatName(
              title: '修改设备名称',
              initial: device.label,
              hint: '设备名称（仅本机）',
            );
            if (name == null || !mounted) return null;
            try {
              await service.renameDevice(device.id, name);
              if (mounted) setState(() {});
              return name;
            } catch (_) {
              if (mounted) showLuminaToast(this.context, '设备名称未能保存，请重试。');
              return null;
            }
          },
        ),
      );
      if (device == null || !mounted) return;
      final remote = await service.createConversation(device);
      final conversation = await widget.repository.importDeviceConversation(
        remote,
      );
      if (!mounted) return;
      await _openConversation(conversation, receiveShare: _shareId != null);
      if (mounted) setState(() => _chatDeviceId = device.id);
    } catch (_) {
      if (mounted) showLuminaToast(context, '设备对话未能建立。请确认已登录、服务器已更新且设备在线，再重试。');
    } finally {
      if (mounted) setState(() => _startingDeviceChat = false);
    }
  }

  bool get _hasChatTarget =>
      ref.read(agentChatServiceProvider).isAllowedTarget(_chatDeviceId);

  bool get _isDshTarget =>
      ref.read(agentChatServiceProvider).isDshTarget(_chatDeviceId);

  Future<bool> _requireChatTarget() async {
    final conversationId = _conversationId;
    try {
      final service = ref.read(agentChatServiceProvider);
      final target = await service.target(conversationId, requireOnline: true);
      if (!mounted || _conversationId != conversationId) return false;
      setState(() => _chatDeviceId = target);
      if (_hasChatTarget) return true;
    } catch (_) {
      if (!mounted) return false;
      showLuminaToast(context, '暂时无法确认聊天设备，请联网后重试。');
      return false;
    }
    showLuminaToast(context, '请通过设备入口选择在线的聊天设备。');
    return false;
  }

  Future<void> _openConversation(
    Conversation conversation, {
    bool receiveShare = false,
  }) async {
    await _persistDraft();
    if (!mounted) return;
    _draftRevision++;
    _changingDraft = true;
    setState(() {
      if (_conversationId != conversation.id) {
        _observedDraftText = '';
        _controller.clear();
        _attachments.clear();
        _appliedShareIds.clear();
        _replyMessage = null;
      }
      _historyStart = 0;
      _historyLimit = 60;
      _highlightMessageId = null;
      _pendingNotificationMessageId = null;
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
    _changingDraft = false;
    await _restoreDraft();
    if (!mounted || _conversationId != conversation.id) return;
    if (receiveShare) await _importSharedDraft();
    if (!mounted || _conversationId != conversation.id) return;
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

  Future<void> _showConversationFilters(
    Map<String, String> devices,
    Map<String, ChatSessionSummary> summaries,
    int total,
  ) async {
    FocusScope.of(context).unfocus();
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(VoidCallback change) {
            setState(change);
            setSheetState(() {});
          }

          return LuminaStack(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('筛选会话', style: LuminaTheme.of(context).textTheme.titleSmall),
              const Text('设备'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  LuminaChip(
                    key: const ValueKey('conversation-device-all'),
                    label: const Text('全部设备'),
                    selected: _conversationDeviceFilter == null,
                    onSelected: (_) =>
                        update(() => _conversationDeviceFilter = null),
                  ),
                  for (final device in devices.entries)
                    LuminaChip(
                      key: ValueKey('conversation-device-${device.key}'),
                      label: Text(device.value),
                      selected: _conversationDeviceFilter == device.key,
                      onSelected: (_) =>
                          update(() => _conversationDeviceFilter = device.key),
                    ),
                ],
              ),
              const Text('状态'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final filter in <ChatSessionState?, String>{
                    null: '全部',
                    ChatSessionState.running: '运行中',
                    ChatSessionState.pending: '待处理',
                    ChatSessionState.failed: '失败',
                  }.entries)
                    LuminaChip(
                      key: ValueKey(
                        'conversation-state-${filter.key?.name ?? 'all'}',
                      ),
                      label: Text(
                        '${filter.value} ${filter.key == null ? total : summaries.values.where((summary) => summary.state == filter.key).length}',
                      ),
                      selected: _conversationStateFilter == filter.key,
                      onSelected: (_) =>
                          update(() => _conversationStateFilter = filter.key),
                    ),
                ],
              ),
              Row(
                children: [
                  LuminaButton(
                    onPressed: () => update(() {
                      _conversationDeviceFilter = null;
                      _conversationStateFilter = null;
                    }),
                    child: const Text('清除筛选'),
                  ),
                  const Spacer(),
                  LuminaButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _conversationList() => OrialisPageScaffold(
    title: '聊天',
    actions: [
      LuminaIconButton(
        onPressed: _startingDeviceChat ? null : _chooseChatDevice,
        icon: const LuminaIcon(LuminaIcons.devices),
        tooltip: '与设备对话',
      ),
    ],
    body: StreamBuilder<List<Conversation>>(
      stream: _conversationsStream,
      initialData: _emittedConversations,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const LuminaEmptyState(text: '会话暂时无法加载，请稍后再试。');
        }
        if (!snapshot.hasData) return const Center(child: LuminaProgress());
        final allConversations = snapshot.data!;
        if (allConversations.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LuminaEmptyState(
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
        final service = ref.read(agentChatServiceProvider);
        final devices = <String, String>{
          for (final conversation in allConversations)
            if (_visibleTargets[conversation.id] case final String deviceId)
              deviceId: service.targetLabel(deviceId) ?? deviceId,
        };
        final summaries = {
          for (final conversation in allConversations)
            conversation.id: ChatSessionSummary.fromEvents(
              _conversationEvents[conversation.id],
            ),
        };
        final query = _conversationSearch.text.trim().toLowerCase();
        final filtering =
            query.isNotEmpty ||
            _conversationDeviceFilter != null ||
            _conversationStateFilter != null;
        final conversations = allConversations.where((conversation) {
          final deviceId = _visibleTargets[conversation.id];
          final deviceLabel = devices[deviceId] ?? '本地历史';
          return (_conversationDeviceFilter == null ||
                  deviceId == _conversationDeviceFilter) &&
              (_conversationStateFilter == null ||
                  summaries[conversation.id]!.state ==
                      _conversationStateFilter) &&
              (query.isEmpty ||
                  conversation.title.toLowerCase().contains(query) ||
                  deviceLabel.toLowerCase().contains(query));
        }).toList();
        final pinnedCount = conversations.where((item) => item.pinned).length;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                LuminaPageHeaderInset.of(context) + 8,
                16,
                6,
              ),
              child: Row(
                key: const ValueKey('conversation-toolbar'),
                children: [
                  Expanded(
                    child: LuminaTextField(
                      key: const ValueKey('conversation-search'),
                      controller: _conversationSearch,
                      hintText: '搜索会话或设备',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  LuminaButton(
                    key: const ValueKey('conversation-filters'),
                    onPressed: () => _showConversationFilters(
                      devices,
                      summaries,
                      allConversations.length,
                    ),
                    child: Text(
                      _conversationDeviceFilter == null &&
                              _conversationStateFilter == null
                          ? '筛选'
                          : '筛选 ${(_conversationDeviceFilter != null ? 1 : 0) + (_conversationStateFilter != null ? 1 : 0)}',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: conversations.isEmpty
                  ? const LuminaEmptyState(text: '没有匹配的会话，试试其他搜索或筛选。')
                  : ReorderableList(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom + 24,
                      ),
                      itemCount: conversations.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        if (filtering ||
                            oldIndex >= pinnedCount ||
                            newIndex >= pinnedCount) {
                          return;
                        }
                        final ids = conversations
                            .take(pinnedCount)
                            .map((item) => item.id)
                            .toList();
                        ids.insert(newIndex, ids.removeAt(oldIndex));
                        try {
                          await widget.repository.reorderPinnedConversations(
                            ids,
                          );
                        } on Object {
                          if (context.mounted) {
                            showLuminaToast(context, '排序未能保存，请重试');
                          }
                        }
                      },
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        return Consumer(
                          key: ValueKey(conversation.id),
                          builder: (context, ref, _) {
                            final latest = ref
                                .watch(
                                  chatLatestMessageProvider((
                                    repository: widget.repository,
                                    conversationId: conversation.id,
                                  )),
                                )
                                .value;
                            final preview =
                                latest == null || !isVisibleChatMessage(latest)
                                ? null
                                : _readableMessage(latest)
                                      .replaceAll('\n', ' ')
                                      .trim();
                            final deviceLabel =
                                devices[_visibleTargets[conversation.id]] ??
                                '本地历史';
                            final status = summaries[conversation.id]!.label;
                            final theme = LuminaTheme.of(context);
                            final colors = theme.colors;
                            final deviceId = _visibleTargets[conversation.id];
                            final deviceColor =
                                deviceId == service.azureDeviceId
                                ? colors.tone(
                                    const Color(0xFF245EAB),
                                    const Color(0xFF8AB4F8),
                                  )
                                : deviceId == service.macDeviceId
                                ? colors.tone(
                                    const Color(0xFF7950A6),
                                    const Color(0xFFC4A7F0),
                                  )
                                : deviceId == service.windowsDeviceId
                                ? colors.tone(
                                    const Color(0xFF167568),
                                    const Color(0xFF7CD5C4),
                                  )
                                : deviceId == service.hakariDeviceId
                                ? colors.tone(
                                    const Color(0xFF995A16),
                                    const Color(0xFFF6BE77),
                                  )
                                : theme.colors.muted;
                            final row = LuminaSurface(
                              key: ValueKey(
                                'conversation-row-${conversation.id}',
                              ),
                              radius: 18,
                              color: Color.alphaBlend(
                                deviceColor.withValues(alpha: .07),
                                theme.colors.surface,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              onTap: _importingShare
                                  ? null
                                  : () => _openConversation(
                                      conversation,
                                      receiveShare: _shareId != null,
                                    ),
                              child: Row(
                                children: [
                                  Container(
                                    key: ValueKey(
                                      'conversation-device-marker-${conversation.id}',
                                    ),
                                    width: 3,
                                    height: 36,
                                    margin: const EdgeInsets.only(right: 10),
                                    decoration: BoxDecoration(
                                      color: deviceColor,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                conversation.pinned
                                                    ? '置顶 · ${conversation.title}'
                                                    : conversation.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme
                                                    .textTheme
                                                    .titleSmall
                                                    .copyWith(
                                                      fontSize: 15,
                                                      height: 1.3,
                                                    ),
                                              ),
                                            ),
                                            if (latest != null) ...[
                                              const SizedBox(width: 8),
                                              Text(
                                                _formatMessageTime(
                                                  latest.createdAt,
                                                ),
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    .copyWith(
                                                      fontSize: 11,
                                                      height: 1.3,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          summaries[conversation.id]!.state ==
                                                  ChatSessionState.ready
                                              ? deviceLabel
                                              : '$deviceLabel · $status',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              .copyWith(
                                                color: deviceColor,
                                                fontSize: 11,
                                                height: 1.3,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          preview != null && preview.isNotEmpty
                                              ? preview
                                              : conversation.type == 'main'
                                              ? '主会话 · 随时开始新的想法'
                                              : '轻触继续对话',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              .copyWith(
                                                fontSize: 13,
                                                height: 1.35,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  LuminaIconButton(
                                    tooltip: '会话选项',
                                    icon: const LuminaIcon(LuminaIcons.more),
                                    onPressed: () =>
                                        _conversationOptions(conversation),
                                  ),
                                ],
                              ),
                            );
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: conversation.pinned && !filtering
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
            ),
          ],
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
          LuminaListRow(
            title: conversation.pinned ? '取消置顶' : '置顶会话',
            subtitle: '置顶后可长按拖动排序',
            onTap: () => Navigator.of(context, rootNavigator: true).pop('pin'),
          ),
          LuminaListRow(
            title: '恢复默认顺序',
            subtitle: '置顶状态保留，按最近更新排序',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('resetOrder'),
          ),
          LuminaListRow(
            title: '修改会话名称',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('rename'),
          ),
          const SizedBox(height: 8),
          if (conversation.type != 'main' && conversation.id != 'default')
            LuminaListRow(
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
    final conversationId = _conversationId;
    final store = _agentEvents;
    if (!await _requireChatTarget() || _conversationId != conversationId) {
      store.actions.release(requestId);
      throw StateError('未绑定聊天设备');
    }
    try {
      if (_isDshTarget && type != 'session.status') {
        throw StateError('Hakari DSH 暂不支持此操作');
      }
      await ref
          .read(realtimeClientProvider)
          .sendEvent(
            kind: type,
            requestId: requestId,
            payload: {...payload, 'conversationId': conversationId},
          );
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        store.actions.release(requestId);
        showLuminaToast(context, '操作暂时无法发送：$error');
      }
      rethrow;
    }
  }

  Future<void> _refreshAgentStatus() async {
    final conversationId = _conversationId;
    final requestId = _requestId();
    final response = Completer<void>();
    final subscription = ref.read(realtimeClientProvider).events.listen((
      event,
    ) {
      if (event.type == 'error' && event.requestId == requestId) {
        if (!response.isCompleted) {
          response.completeError(StateError('设备状态暂时不可用'));
        }
        return;
      }
      final payload = event.payload;
      if (payload['requestId'] == requestId &&
          payload['conversationId'] == conversationId &&
          const {
            'session.status',
            'session.update',
          }.contains(resolveAgentEnvelope(event).kind) &&
          !response.isCompleted) {
        response.complete();
      }
    });
    final timeout = Timer(const Duration(seconds: 15), () {
      if (!response.isCompleted) {
        response.completeError(TimeoutException('设备状态刷新超时'));
      }
    });
    try {
      await Future.wait<void>([
        _sendAgentAction('session.status', requestId, const {}),
        response.future,
      ], eagerError: true);
    } finally {
      timeout.cancel();
      await subscription.cancel();
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
    final text = _readableMessage(message).trim();
    final attachmentNames = _decodeAttachments(message.attachmentsJson)
        .map((item) => item['name'] as String? ?? '附件')
        .join('、');
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
          await Clipboard.setData(
            ClipboardData(text: _readableMessage(message)),
          );
          if (mounted) showLuminaToast(context, '已复制');
        },
        onSelectText: () {
          unawaited(
            showLuminaSheet<void>(
              context: context,
              builder: (_) => LuminaSelectableText(_readableMessage(message)),
            ),
          );
        },
        onExplain: () {
          _replyTo(message);
          _fillPrompt('请解释这条引用消息的含义和关键点。');
        },
      );

  Future<void> _jumpToQuotedMessage(
    String? id,
    List<Message> messages, {
    bool waitForSync = false,
  }) async {
    if (id == null) return;
    final index = messages.indexWhere((item) => item.id == id);
    if (index < 0) {
      final conversationId = _conversationId;
      final required = await widget.repository.messageWindowSizeFor(
        conversationId,
        id,
      );
      if (!mounted || _conversationId != conversationId) return;
      if (required == null) {
        if (waitForSync) {
          _pendingNotificationMessageId = id;
          return;
        }
        showLuminaToast(context, '原消息暂不可用，引用快照仍保留。');
        return;
      }
      setState(() {
        _followLatest = false;
        _positioningLatest = false;
        _historyStart = 0;
        if (required > _historyLimit) _historyLimit = required;
        _pendingNotificationMessageId = id;
      });
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
          LuminaListRow(
            title: '拍照',
            leading: const LuminaIcon(LuminaIcons.camera),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('camera'),
          ),
          LuminaListRow(
            title: '选择照片',
            leading: const LuminaIcon(LuminaIcons.image),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('photos'),
          ),
          LuminaListRow(
            title: '选择文件',
            leading: const LuminaIcon(LuminaIcons.attachment),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('files'),
          ),
          if (!_isDshTarget)
            LuminaListRow(
              title: '指令',
              leading: const LuminaIcon(LuminaIcons.terminal),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('commands'),
            ),
          LuminaListRow(
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
            LuminaListRow(
              title: hermesShortcuts[i].title,
              subtitle: hermesShortcuts[i].description,
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('command:$i'),
            ),
          LuminaListRow(
            title: '重置上下文',
            subtitle: '开始新的 Hermes 上下文，保留 App 历史',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('reset'),
          ),
          LuminaListRow(
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
          LuminaListRow(
            title: '总结当前对话',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('summary'),
          ),
          LuminaListRow(
            title: '提取待办',
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('tasks'),
          ),
          if (_replyMessage != null)
            LuminaListRow(
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

  Future<void> _sendComposer() async {
    if (_importingShare) return;
    final text = _controller.text;
    if (text.trimLeft().startsWith('/') && _chatDeviceId == null) {
      if (!await _requireChatTarget()) return;
    }
    if (!mounted) return;
    if (_isDshTarget || !text.trimLeft().startsWith('/')) {
      return _send();
    }
    if (_sending) return;
    if (_attachments.isNotEmpty) {
      showLuminaToast(context, '指令不附带文件，请先移除附件。');
      return;
    }
    final conversationId = _conversationId;
    final drafts = _drafts;
    setState(() => _sending = true);
    try {
      final sent = await _sendHermesCommand(text.trim());
      if (sent &&
          mounted &&
          _conversationId == conversationId &&
          _drafts == drafts &&
          _controller.text == text) {
        _controller.clear();
      }
      if (sent && drafts != null) {
        unawaited(() async {
          try {
            await (await drafts).clearSubmitted(conversationId, text);
          } catch (_) {
            if (mounted) showLuminaToast(context, '指令已发送，但旧草稿未能清理。');
          }
        }());
      }
    } on Object {
      // The existing command sender reports the error; keep the draft to retry.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send() async {
    if (_sending || (_controller.text.trim().isEmpty && _attachments.isEmpty)) {
      return;
    }
    setState(() => _sending = true);
    if (!await _requireChatTarget()) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;
    if (_isDshTarget && _attachments.isNotEmpty) {
      setState(() => _sending = false);
      showLuminaToast(context, 'Hakari DSH 当前只支持文字，附件和草稿已保留。');
      return;
    }
    final content = _controller.text;
    final draftStore = _drafts;
    final sentConversationId = _conversationId;
    final attachments = List<AttachmentRecord>.from(_attachments);
    final reply = _replyMessage;
    final previousMessageId = _chatController.lastMessageId;
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
          if (_conversationId == sentConversationId) {
            setState(() {
              _attachments.addAll(attachments);
              _replyMessage = reply;
            });
          }
          showLuminaToast(context, '消息未能保存，内容已保留，请重试。');
        } else {
          _failedMessages.add(_chatController.lastMessageId!);
          showLuminaToast(context, '消息已保存在设备，联网后可重试发送。');
        }
      }
    } finally {
      if (draftStore != null &&
          _chatController.lastMessageId != previousMessageId) {
        if (mounted &&
            _conversationId == sentConversationId &&
            _drafts == draftStore &&
            _controller.text == content) {
          _controller.clear();
        }
        unawaited(() async {
          try {
            await (await draftStore).clearSubmitted(
              sentConversationId,
              content,
              attachmentPaths: attachments.map(
                (attachment) => attachment.localPath,
              ),
            );
          } catch (_) {
            if (mounted) showLuminaToast(context, '消息已保存，但旧草稿未能清理。');
          }
        }());
      }
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _retryMessage(String messageId) async {
    if (_sending) return;
    setState(() => _sending = true);
    if (!await _requireChatTarget()) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _failedMessages.remove(messageId);
    });
    try {
      await _chatController.retry(messageId, conversationId: _conversationId);
    } on Object catch (error) {
      if (mounted) {
        _failedMessages.add(messageId);
        showLuminaToast(context, '重试失败：$error');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// `true` = turn fully unprocessed; `false` = partial tool run; `null` = healthy.
  /// Matches Hermes `turn_failure_copy` boundary notices that close a failed turn.
  bool? _lastFailedTurn(List<Message>? items) {
    if (items == null || items.isEmpty) return null;
    for (final message in items.reversed) {
      final text = message.content.trim();
      if (text.isEmpty) continue;
      if (message.role != 'assistant') return null;
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
          LuminaListRow(
            title: '新建设备对话',
            leading: const LuminaIcon(LuminaIcons.devices),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('device'),
          ),
          if (!_isDshTarget)
            LuminaListRow(
              title: '工作区文件与终端',
              leading: const LuminaIcon(LuminaIcons.folder),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('workspace'),
            ),
          LuminaListRow(
            title: '复制会话记录',
            leading: const LuminaIcon(LuminaIcons.file),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('transcript'),
          ),
          LuminaListRow(
            title: '修改会话名称',
            leading: const LuminaIcon(LuminaIcons.settings),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('rename'),
          ),
          if (!_isDshTarget)
            LuminaListRow(
              title: '模型与思考强度',
              leading: const LuminaIcon(LuminaIcons.sparkles),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('model'),
            ),
          if (!_isDshTarget)
            LuminaListRow(
              title: 'Hermes 命令',
              leading: const LuminaIcon(LuminaIcons.terminal),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('command'),
            ),
          const SizedBox(height: 8),
          if (!_isDshTarget)
            LuminaListRow(
              title: '主动投递',
              leading: const LuminaIcon(LuminaIcons.notification),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('delivery'),
            ),
          const SizedBox(height: 8),
          if (!_isDshTarget)
            LuminaListRow(
              title: '会话控制',
              leading: const LuminaIcon(LuminaIcons.settings),
              onTap: () =>
                  Navigator.of(context, rootNavigator: true).pop('session'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'workspace') {
      if (!await _requireChatTarget() || !mounted) return;
      final client = WorkspaceClient(
        realtime: ref.read(realtimeClientProvider),
        config: ref.read(appConfigProvider),
        conversationId: _conversationId,
      );
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(builder: (_) => WorkspacePage(client: client)),
      );
    }
    if (action == 'transcript') {
      final messages = await widget.repository
          .watchMessages(_conversationId)
          .first;
      final text = messages
          .map(
            (message) =>
                '${message.role == 'user' ? '我' : ref.read(agentChatServiceProvider).agentLabel(_chatDeviceId)} · ${message.createdAt}\n${_readableMessage(message)}',
          )
          .join('\n\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) showLuminaToast(context, '会话记录已复制');
    }
    if (action == 'rename') {
      final conversations = await widget.repository.watchConversations().first;
      final current = conversations.where((item) => item.id == _conversationId);
      if (mounted && current.isNotEmpty) {
        await _renameConversation(current.first);
      }
    }
    if (action == 'device') await _chooseChatDevice();
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
      child: Column(
        children: [
          if (_shareId != null) _sharePreview(),
          Expanded(
            child: LuminaBranchTransition(
              index: _showingConversation ? 1 : 0,
              children: [
                _conversationList(),
                _hasOpenedConversation
                    ? Consumer(
                        builder: (context, ref, _) =>
                            _conversationDetail(context, ref),
                      )
                    : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sharePreview() {
    final payload = ref.read(chatShareCoordinatorProvider)?.pending;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: LuminaSurface(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _importingShare
                          ? '正在加入草稿…'
                          : _shareImportFailed
                          ? '导入未完成，原分享已保留'
                          : '选择会话接收分享',
                    ),
                    Text(
                      [
                        if (payload?.text.isNotEmpty == true) payload!.text,
                        if (payload?.files.isNotEmpty == true)
                          '${payload!.files.length} 个附件',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Text('加入草稿后，由你确认发送'),
                  ],
                ),
              ),
              if (_shareImportFailed && !_importingShare)
                LuminaButton(
                  onPressed: _importSharedDraft,
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conversationDetail(BuildContext context, WidgetRef ref) {
    final colors = LuminaTheme.of(context).colors;
    final messages = ref.watch(
      chatMessageWindowProvider((
        repository: widget.repository,
        conversationId: _conversationId,
        limit: _historyLimit + 1,
      )),
    );
    const headerHeight = 64.0;
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
                      error: (error, _) => const LuminaEmptyState(
                        text: '消息暂时无法加载，请稍后再试。',
                        card: false,
                      ),
                      data: (window) {
                        final hasEarlier = window.length > _historyLimit;
                        final items = (hasEarlier ? window.sublist(1) : window)
                            .where(isVisibleChatMessage)
                            .toList();
                        final notificationMessage =
                            _pendingNotificationMessageId;
                        if (notificationMessage != null) {
                          _pendingNotificationMessageId = null;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _jumpToQuotedMessage(
                                notificationMessage,
                                items,
                                waitForSync: true,
                              );
                            }
                          });
                        }
                        // Latest identity + content hash detects a new final
                        // message without building a full-body signature string.
                        final last = items.isEmpty ? null : items.last;
                        final signature =
                            '$_conversationId:${last?.id ?? ''}:${last?.content.hashCode ?? 0}:${last?.attachmentsJson.hashCode ?? 0}';
                        if (_messageSignature != signature) {
                          _messageSignature = signature;
                          _contentArrived();
                        }
                        return items.isEmpty
                            ? ListView(
                                padding: const EdgeInsets.only(
                                  top: headerHeight + 12,
                                ),
                                children: [
                                  if (hasEarlier)
                                    LuminaButton(
                                      primary: false,
                                      onPressed: () => setState(() {
                                        _historyLimit += 30;
                                      }),
                                      child: const Text('查看更早消息'),
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: AgentEventsPanel(
                                      key: ValueKey(
                                        'agent-events-$_conversationId',
                                      ),
                                      store: _agentEvents,
                                      showActivity: false,
                                      showThinking: true,
                                      showClarifications: false,
                                      onRefresh: _chatDeviceId == null
                                          ? null
                                          : _refreshAgentStatus,
                                      onPromptSelected: _fillPrompt,
                                      onAction: _sendAgentAction,
                                    ),
                                  ),
                                  if (_agentEvents.streams.isEmpty &&
                                      !_agentEvents.typing &&
                                      chatThinkingLabel(_agentEvents) == null)
                                    const LuminaEmptyState(
                                      text: '从一句话开始。\n记录想法，或一起安排今天。',
                                      card: false,
                                    ),
                                ],
                              )
                            : NotificationListener<ScrollMetricsNotification>(
                                onNotification: (notification) {
                                  if (notification.depth == 0 &&
                                      !_userDragging &&
                                      _followLatest) {
                                    _queueLatest();
                                  }
                                  return false;
                                },
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: (notification) {
                                    if (notification.depth != 0) return false;
                                    if (notification
                                            is ScrollStartNotification &&
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
                                            _historyStart.clamp(
                                              0,
                                              items.length,
                                            ) +
                                            2 +
                                            (hasEarlier || _historyStart > 0
                                                ? 1
                                                : 0),
                                        itemBuilder: (context, index) {
                                          final start = _historyStart.clamp(
                                            0,
                                            items.length,
                                          );
                                          final showEarlier =
                                              hasEarlier || start > 0;
                                          if (showEarlier && index == 0) {
                                            return LuminaButton(
                                              primary: false,
                                              onPressed: () => setState(() {
                                                _followLatest = false;
                                                _positioningLatest = false;
                                                if (start > 0) {
                                                  _historyStart = (start - 30)
                                                      .clamp(0, items.length);
                                                } else {
                                                  _historyLimit += 30;
                                                }
                                              }),
                                              child: const Text('查看更早消息'),
                                            );
                                          }
                                          final messageIndex =
                                              index +
                                              start -
                                              (showEarlier ? 1 : 0);
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
                                                      onPromptSelected:
                                                          _fillPrompt,
                                                      highlighted:
                                                          _highlightMessageId ==
                                                          message.id,
                                                      onQuoteTap: () =>
                                                          _jumpToQuotedMessage(
                                                            message
                                                                .replyToMessageId,
                                                            items,
                                                          ),
                                                      pluginReceived:
                                                          _agentEvents
                                                              .receivedMessageIds
                                                              .contains(
                                                                message.id,
                                                              ),
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
                                              persistedMessageIds: {
                                                for (final message in items)
                                                  if (message.role ==
                                                      'assistant')
                                                    message.id,
                                              },
                                              showActivity: false,
                                              showThinking: true,
                                              showClarifications: false,
                                              onRefresh: _chatDeviceId == null
                                                  ? null
                                                  : _refreshAgentStatus,
                                              onPromptSelected: _fillPrompt,
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
                    child: LuminaTopBar(
                      title: _conversationTitle,
                      leading: LuminaIconButton(
                        onPressed: _closeConversation,
                        icon: const LuminaIcon(LuminaIcons.back),
                        tooltip: '返回会话列表',
                      ),
                      actions: [
                        ChatHeaderStatus(
                          key: ValueKey('header-status-$_conversationId'),
                          store: _agentEvents,
                          agents: ref.read(agentChatServiceProvider),
                          deviceId: _chatDeviceId,
                          sending: _sending,
                          lastTurnFailed:
                              _lastFailedTurn(messages.valueOrNull) != null,
                          onRefresh: _chatDeviceId == null
                              ? null
                              : _refreshAgentStatus,
                          onSessionAction: _isDshTarget
                              ? null
                              : _runSessionAction,
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
            if (_hasNewMessages || _highlightMessageId != null)
              LuminaButton(
                onPressed: () {
                  setState(() {
                    _historyStart = 0;
                    _highlightMessageId = null;
                    _followLatest = true;
                    _hasNewMessages = false;
                  });
                  _queueLatest();
                },
                child: Text(_hasNewMessages ? '新消息 ↓' : '回到最新 ↓'),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AgentRequestsPanel(
                key: ValueKey('requests-$_conversationId'),
                store: _agentEvents,
                onAction: _sendAgentAction,
              ),
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
                          title: reply.role == 'user'
                              ? '回复自己'
                              : '回复 ${ref.read(agentChatServiceProvider).agentLabel(_chatDeviceId)}',
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
                    SlashCommandSuggestions(
                      controller: _controller,
                      enabled: !_sending && !_isDshTarget,
                      onSelected: (shortcut) {
                        _controller.value = TextEditingValue(
                          text: shortcut.command,
                          selection: TextSelection.collapsed(
                            offset: shortcut.command.length,
                          ),
                        );
                        _composerFocus.requestFocus();
                      },
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
                            readOnly: _importingShare,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendComposer(),
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
                          onPressed: _sending || _importingShare
                              ? null
                              : _sendComposer,
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

String _readableMessage(Message message) => message.role == 'assistant'
    ? responseUiPlainText(message.content)
    : message.content;

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    this.onPromptSelected,
    this.onRetry,
    this.onQuoteTap,
    this.highlighted = false,
    this.pluginReceived = false,
    this.failed = false,
    this.sending = false,
  });
  final Message message;
  final ValueChanged<String>? onPromptSelected;
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
        : '等待上传，点击重试';
    final canRetry = isUser && pending && !sending && onRetry != null;
    final metadata = Semantics(
      key: ValueKey('message-status-${message.id}'),
      label: '${_formatMessageTime(message.createdAt)} $statusLabel',
      button: canRetry,
      excludeSemantics: true,
      child: LuminaTap(
        behavior: HitTestBehavior.opaque,
        onTap: canRetry ? onRetry : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatMessageTime(message.createdAt),
              style: LuminaTheme.of(context).textTheme.labelSmall
                  .copyWith(color: colors.muted, fontSize: 11),
            ),
            if (isUser) ...[
              const SizedBox(width: 4),
              SizedBox(
                width: 12,
                height: 12,
                child: sending && pending
                    ? const LuminaProgress()
                    : Center(
                        child: Text(
                          status,
                          style: LuminaTheme.of(context).textTheme.labelSmall
                              .copyWith(color: colors.muted, fontSize: 11),
                        ),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
    final inlineMetadata =
        isUser && attachments.isEmpty && message.content.isNotEmpty;
    final content = Column(
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
              : SafeMarkdownView(
                  source: message.content,
                  allowResponseUi: message.role == 'assistant',
                  onPromptSelected: onPromptSelected,
                  actionScope: message.id,
                ),
        for (final attachment in attachments)
          ChatAttachmentTile(attachment: attachment),
        if (!inlineMetadata) ...[
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: metadata),
        ],
      ],
    );
    // Keep the assistant's reading surface open while isolating each message's paint.
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: highlighted ? colors.accentSoft : const Color(0x00000000),
          borderRadius: BorderRadius.circular(16),
        ),
        child: isUser
            ? LuminaChatBubble(isUser: true, child: content)
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(width: double.infinity, child: content),
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
            LuminaListRow(
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
          const SizedBox(height: LuminaSpacing.controlGap),
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
              const SizedBox(width: LuminaSpacing.controlGap),
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
          const SizedBox(height: LuminaSpacing.controlGap),
          Text(
            '消息未处理或会话异常时，可先「重试」；仍不行再「重置」。',
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: LuminaSpacing.controlGap),
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
          const SizedBox(height: LuminaSpacing.controlGap),
          Row(
            children: [
              Expanded(
                child: LuminaTextField(
                  controller: _titleController,
                  enabled: !_sending,
                  hintText: '设置会话标题',
                ),
              ),
              const SizedBox(width: LuminaSpacing.controlGap),
              LuminaIconButton(
                onPressed: _sending ? null : _submitTitle,
                icon: const LuminaIcon(LuminaIcons.check),
                tooltip: '保存标题',
              ),
            ],
          ),
          const SizedBox(height: LuminaSpacing.controlGap),
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
