import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

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
import '../../features/chat/application/chat_controller.dart';
import '../../features/chat/domain/agent_event_state.dart';
import '../../features/chat/presentation/agent_event_cards.dart';
import '../../features/chat/presentation/safe_markdown.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    required this.repository,
    this.conversationId = 'default',
    super.key,
  });

  final ChatRepository repository;
  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _latestMessageAnchor = GlobalKey();
  final _imagePicker = ImagePicker();
  final _attachmentBridge = AttachmentBridge();
  final List<AttachmentRecord> _attachments = [];
  final Map<String, AgentEventStore> _conversationEvents = {};
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
  bool _approvalSheetOpen = false;
  bool _followLatest = true, _hasNewMessages = false, _scrollScheduled = false;
  bool _userDragging = false;
  bool _positioningLatest = true;
  int _alignRetries = 0;
  String? _messageSignature;
  final Set<String> _failedMessages = {};

  // Realtime deltas arrive in bursts. Apply them all and rebuild at most once
  // per microtask turn so a 20-delta token stream is one frame, not twenty.
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
    _syncFollowFromPosition();
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
    scheduleMicrotask(_flushAgentEvents);
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
      store.applySilent(event);
      touchedStores.add(store);
      final kind = resolved.kind;
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
    _scrollController.addListener(_onScroll);
    _conversationId = widget.conversationId;
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
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _realtimeSubscription.cancel();
    super.dispose();
  }

  Future<void> _openConversation(Conversation conversation) async {
    setState(() {
      _conversationId = conversation.id;
      _conversationTitle = conversation.title;
      _showingConversation = true;
      _hasOpenedConversation = true;
      _followLatest = true;
      _hasNewMessages = false;
      _messageSignature = null;
      _positioningLatest = true;
      _userDragging = false;
      _alignRetries = 0;
    });
    const LuminaConversationVisibility(true).dispatch(context);
    _queueLatest();
    // Safety valve: never leave the transcript blank if variable-height
    // bubbles keep revising the scroll extent.
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (mounted && _positioningLatest) {
        setState(() => _positioningLatest = false);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _presentApproval());
  }

  Future<void> _createConversation() async {
    final conversation = await widget.repository.createConversation();
    if (mounted) await _openConversation(conversation);
  }

  Widget _conversationList() => OrialisPageScaffold(
    title: '聊天',
    subtitle: '想法在这里，慢慢成形。',
    actions: [
      LuminaIconButton(
        onPressed: _createConversation,
        icon: const LuminaIcon(LuminaIcons.add),
        tooltip: '新建会话',
      ),
    ],
    body: StreamBuilder<List<Conversation>>(
      stream: widget.repository.watchConversations(),
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
        return ListView.separated(
          itemCount: conversations.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final conversation = conversations[index];
            final history = ref
                .watch(
                  chatMessagesProvider((
                    repository: widget.repository,
                    conversationId: conversation.id,
                  )),
                )
                .value;
            final latest = history?.lastOrNull;
            final preview = latest?.content.replaceAll('\n', ' ').trim();
            return OrialisListRow(
              title: conversation.title,
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
                  conversation.type == 'main'
                      ? const LuminaIcon(LuminaIcons.chevronRight)
                      : LuminaIconButton(
                          tooltip: '会话选项',
                          icon: const LuminaIcon(LuminaIcons.more),
                          onPressed: () => _conversationOptions(conversation),
                        ),
                ],
              ),
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
            title: '重命名',
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          const SizedBox(height: 8),
          OrialisListRow(
            title: '删除会话',
            subtitle: '仅删除此普通会话',
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    );
    if (action == 'rename' && mounted) await _renameConversation(conversation);
    if (action == 'delete' && mounted) {
      final confirmed = await showLuminaDialog<bool>(
        context: context,
        title: '删除会话？',
        content: Text('“${conversation.title}”将被删除。'),
        actions: [
          LuminaButton(
            onPressed: () => Navigator.pop(context, false),
            primary: false,
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      );
      if (confirmed == true) {
        await widget.repository.deleteConversation(conversation);
      }
    }
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final title = await showLuminaDialog<String>(
      context: context,
      title: '重命名会话',
      content: LuminaTextField(
        controller: controller,
        autofocus: true,
        hintText: '会话名称',
      ),
      actions: [
        LuminaButton(
          primary: false,
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        LuminaButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('保存'),
        ),
      ],
    );
    controller.dispose();
    if (title != null && title.trim().isNotEmpty) {
      await widget.repository.renameConversation(conversation, title);
      if (mounted && conversation.id == _conversationId) {
        setState(() => _conversationTitle = title.trim());
      }
    }
  }

  Future<void> _sendAgentAction(
    String type,
    String requestId,
    Map<String, dynamic> payload,
  ) async {
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

  Future<void> _showHermesCommand() async {
    await showLuminaSheet<void>(
      context: context,
      builder: (context) => _CommandComposer(
        onSend: (command) async {
          await _sendAgentAction('hermes.command', _requestId(), {
            'command': command,
          });
          if (context.mounted) Navigator.pop(context);
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
        onAction: (type, payload) => _sendAgentAction(type, _requestId(), {
          'sessionId': _conversationId,
          ...payload,
        }),
      ),
    );
  }

  Future<void> _chooseAttachment() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: LuminaStack(
          mainAxisSize: MainAxisSize.min,
          children: [
            OrialisListRow(
              leading: const LuminaIcon(LuminaIcons.camera),
              title: '拍照',
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            OrialisListRow(
              leading: const LuminaIcon(LuminaIcons.image),
              title: '选择照片',
              onTap: () => Navigator.pop(context, 'photos'),
            ),
            OrialisListRow(
              leading: const LuminaIcon(LuminaIcons.attachment),
              title: '选择文件',
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
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
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
            const SizedBox(height: 12),
            LuminaButton(
              primary: false,
              onPressed: () => Navigator.pop(context, false),
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
      final file = File(path);
      if (!await file.exists()) continue;
      final size = await file.length();
      if (size == 0 || size > 20 * 1024 * 1024) {
        if (mounted) {
          showLuminaToast(context, '${path.split('/').last} 超过 20 MB 或为空');
        }
        continue;
      }
      additions.add(await _attachmentBridge.importFile(path));
    }
    if (mounted && additions.isNotEmpty) {
      setState(() => _attachments.addAll(additions));
    }
  }

  Future<void> _send() async {
    if (_sending || (_controller.text.trim().isEmpty && _attachments.isEmpty)) {
      return;
    }
    final content = _controller.text;
    final attachments = List<AttachmentRecord>.from(_attachments);
    final previousMessageId = _chatController.lastMessageId;
    _controller.clear();
    setState(() => _attachments.clear());
    setState(() => _sending = true);
    _followLatest = true;
    _hasNewMessages = false;
    try {
      await _chatController.send(
        conversationId: _conversationId,
        content: content.trim(),
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
          setState(() => _attachments.addAll(attachments));
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
    setState(() {
      _sending = true;
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
            title: 'Hermes 命令',
            leading: const LuminaIcon(LuminaIcons.terminal),
            onTap: () => Navigator.pop(context, 'command'),
          ),
          const SizedBox(height: 8),
          OrialisListRow(
            title: '主动投递',
            leading: const LuminaIcon(LuminaIcons.notification),
            onTap: () => Navigator.pop(context, 'delivery'),
          ),
          const SizedBox(height: 8),
          OrialisListRow(
            title: '会话控制',
            leading: const LuminaIcon(LuminaIcons.settings),
            onTap: () => Navigator.pop(context, 'session'),
          ),
        ],
      ),
    );
    if (!mounted) return;
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
  Widget build(BuildContext context) => LuminaBranchTransition(
    index: _showingConversation ? 1 : 0,
    children: [
      _conversationList(),
      _hasOpenedConversation
          ? _conversationDetail(context)
          : const SizedBox.shrink(),
    ],
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
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (!_showingConversation) return false;
        _closeConversation();
        return true;
      },
      child: ColoredBox(
        color: colors.paper,
        child: SafeArea(
          child: Column(
            children: [
              OrialisTopBar(
                title: _conversationTitle,
                leading: LuminaIconButton(
                  onPressed: _closeConversation,
                  icon: const LuminaIcon(LuminaIcons.back),
                  tooltip: '返回会话列表',
                ),
                actions: [
                  LuminaIconButton(
                    onPressed: _showChatOptions,
                    icon: const LuminaIcon(LuminaIcons.more),
                    tooltip: '更多会话操作',
                  ),
                ],
              ),
              Builder(
                builder: (context) {
                  final lastFailedTurn = _lastFailedTurn(messages.valueOrNull);
                  final banner = action == null && !pendingApproval && lastFailedTurn == null
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
                                      const LuminaIcon(
                                        LuminaIcons.warning,
                                        size: 16,
                                      ),
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
                                            : () => _runSessionAction(
                                                'session.retry',
                                              ),
                                        child: const Text('重试'),
                                      ),
                                      const SizedBox(width: 8),
                                      LuminaButton(
                                        primary: false,
                                        onPressed: _sending
                                            ? null
                                            : () => _runSessionAction(
                                                'session.reset',
                                              ),
                                        child: const Text('重置'),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      const LuminaIcon(
                                        LuminaIcons.sparkles,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          pendingApproval
                                              ? '有一项操作等待你确认'
                                              : action!,
                                          style: LuminaTheme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
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
              ),
              Expanded(
                child: messages.when(
                  loading: () => const Center(child: LuminaProgress()),
                  error: (error, _) => const OrialisEmptyState(
                    text: '消息暂时无法加载，请稍后再试。',
                    card: false,
                  ),
                  data: (items) {
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
                        ? const OrialisEmptyState(
                            text: '从一句话开始。\n记录想法，或一起安排今天。',
                            card: false,
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
                              ignoring: _positioningLatest && _alignRetries < 3,
                              child: Opacity(
                                opacity: _positioningLatest ? 0 : 1,
                                child: ListView.builder(
                                  key: ValueKey(_conversationId),
                                  controller: _scrollController,
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    12,
                                    20,
                                    20,
                                  ),
                                  itemCount: items.length + 2,
                                  itemBuilder: (context, index) {
                                    if (index < items.length) {
                                      final message = items[index];
                                      return _MessageBubble(
                                        key: ValueKey(message.id),
                                        message: message,
                                        pluginReceived: _agentEvents
                                            .receivedMessageIds
                                            .contains(message.id),
                                        failed: _failedMessages.contains(
                                          message.id,
                                        ),
                                        sending:
                                            _sending &&
                                            _chatController.lastMessageId ==
                                                message.id,
                                        onRetry:
                                            message.syncStatus ==
                                                'pendingCreate'
                                            ? () => _retryMessage(message.id)
                                            : null,
                                      );
                                    }
                                    if (index == items.length) {
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
                              minLines: 1,
                              maxLines: 4,
                              hintText: '写消息…',
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          LuminaIconButton(
                            onPressed: _sending ? null : _chooseAttachment,
                            icon: const LuminaIcon(LuminaIcons.add),
                            tooltip: '添加照片或文件',
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
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.pluginReceived = false,
    this.failed = false,
    this.sending = false,
  });
  final Message message;
  final VoidCallback? onRetry;
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
      child: OrialisChatBubble(
        isUser: isUser,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                            style: LuminaTheme.of(context).textTheme.labelSmall,
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

class _CommandComposer extends StatefulWidget {
  const _CommandComposer({required this.onSend});
  final Future<void> Function(String command) onSend;

  @override
  State<_CommandComposer> createState() => _CommandComposerState();
}

class _CommandComposerState extends State<_CommandComposer> {
  final _controller = TextEditingController();
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
            '结果会显示在聊天时间线中；旧服务端会安全忽略此扩展入口。',
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class _SessionControls extends StatefulWidget {
  const _SessionControls({required this.onAction});
  final Future<void> Function(String type, Map<String, dynamic> payload)
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
      await widget.onAction(type, payload);
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

  String _successCopy(String type) => switch (type) {
    'session.create' => '已新建会话。',
    'session.reset' => '已重置会话上下文。',
    'session.resume' => '已请求恢复会话。',
    'session.status' => '已查询会话状态，详情见时间线。',
    'session.title' => '已更新会话标题。',
    'session.retry' => '已重试上一条消息。',
    'session.stop' => '已请求停止后台任务。',
    _ => '操作已发送。',
  };

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
                onPressed: _sending ? null : () => _run('session.create'),
                icon: const LuminaIcon(LuminaIcons.add),
                child: const Text('新建'),
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
