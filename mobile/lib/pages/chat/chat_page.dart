import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
import '../../core/database/app_database.dart';
import '../../core/attachments/attachment_bridge.dart';
import '../../core/realtime/mobile_realtime_client.dart';
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
  final _imagePicker = ImagePicker();
  final _attachmentBridge = AttachmentBridge();
  final List<AttachmentRecord> _attachments = [];
  final _agentEvents = AgentEventStore();
  late final StreamSubscription<MobileEnvelope> _realtimeSubscription;
  late String _conversationId;
  late final ChatController _chatController;
  bool _sending = false;
  bool _deliveryEnabled = false;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    _chatController = ChatController(
      repository: widget.repository,
      flush: () => ref.read(syncCoordinatorProvider).requestSync(),
    );
    final realtime = ref.read(realtimeClientProvider);
    _realtimeSubscription = realtime.events.listen((event) {
      if (event.type == 'message') return;
      if (!mounted) return;
      setState(() => _agentEvents.apply(event));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _realtimeSubscription.cancel();
    super.dispose();
  }

  Future<void> _showConversations() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: StreamBuilder<List<Conversation>>(
          stream: widget.repository.watchConversations(),
          builder: (context, snapshot) {
            final conversations = snapshot.data ?? const <Conversation>[];
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '会话',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '新建会话',
                        icon: const Icon(Icons.add),
                        onPressed: () async {
                          final conversation = await widget.repository
                              .createConversation();
                          if (sheetContext.mounted) {
                            Navigator.pop(sheetContext, conversation.id);
                          }
                        },
                      ),
                    ],
                  ),
                  if (conversations.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('正在同步会话…'),
                    )
                  else
                    ...conversations.map(
                      (conversation) => ListTile(
                        selected: conversation.id == _conversationId,
                        leading: Icon(
                          conversation.type == 'main'
                              ? Icons.home_outlined
                              : Icons.chat_bubble_outline,
                        ),
                        title: Text(conversation.title),
                        subtitle: Text(
                          conversation.type == 'main' ? '主会话' : '普通会话',
                        ),
                        onTap: () =>
                            Navigator.pop(sheetContext, conversation.id),
                        trailing: conversation.type == 'main'
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (action) async {
                                  if (action == 'rename') {
                                    await _renameConversation(conversation);
                                  } else if (action == 'delete') {
                                    await widget.repository.deleteConversation(
                                      conversation,
                                    );
                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext);
                                    }
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重命名'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (selected != null && mounted && selected != _conversationId) {
      setState(() => _conversationId = selected);
    }
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null && title.trim().isNotEmpty) {
      await widget.repository.renameConversation(conversation, title);
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作暂时无法发送：$error')));
      }
      rethrow;
    }
  }

  String _requestId() => const Uuid().v7();

  Future<void> _showHermesCommand() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('主动投递'),
            subtitle: const Text('允许 Agent 将重要结果推送到此设备'),
            value: _deliveryEnabled,
            onChanged: (enabled) async {
              setSheetState(() => _deliveryEnabled = enabled);
              setState(() => _deliveryEnabled = enabled);
              await _sendAgentAction('delivery.notification', _requestId(), {
                'enabled': enabled,
              });
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showSessionControls() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SessionControls(
        onAction: (type, payload) => _sendAgentAction(type, _requestId(), {
          'sessionId': _conversationId,
          ...payload,
        }),
      ),
    );
  }

  Future<void> _chooseAttachment() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final result = await FilePicker.pickFiles();
      if (result.isNotEmpty) {
        await _addPaths(result.map((file) => file.path).whereType<String>());
      }
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('选择照片'),
              onTap: () => Navigator.pop(context, 'photos'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('选择文件'),
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
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
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final additions = <AttachmentRecord>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final size = await file.length();
      if (size == 0 || size > 20 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${path.split('/').last} 超过 20 MB 或为空')),
          );
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
    _controller.clear();
    setState(() => _attachments.clear());
    setState(() => _sending = true);
    try {
      await _chatController.send(
        conversationId: _conversationId,
        content: content.trim(),
        attachmentsJson: jsonEncode(
          attachments.map((attachment) => attachment.toJson()).toList(),
        ),
      );
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _retryMessage(String messageId) async {
    try {
      await _chatController.retry(messageId);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重试失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(
      chatMessagesProvider((
        repository: widget.repository,
        conversationId: _conversationId,
      )),
    );
    final desktop =
        MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.paper,
        elevation: 0,
        titleSpacing: 4,
        title: StreamBuilder<List<Conversation>>(
          stream: widget.repository.watchConversations(),
          builder: (context, snapshot) {
            final conversation = snapshot.data
                ?.where((item) => item.id == _conversationId)
                .firstOrNull;
            return InkWell(
              borderRadius: BorderRadius.circular(AppRadius.control),
              onTap: desktop ? null : _showConversations,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircleAvatar(
                      radius: 17,
                      backgroundColor: AppColors.accentSoft,
                      child: Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          conversation?.title ?? '聊天',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Orialis 助手',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted),
                        ),
                      ],
                    ),
                    if (!desktop)
                      const Icon(Icons.keyboard_arrow_down, size: 18),
                  ],
                ),
              ),
            );
          },
        ),
        actions: [
          IconButton(
            onPressed: _showHermesCommand,
            icon: const Icon(Icons.terminal),
            tooltip: 'Hermes 命令',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'delivery') _showDeliveryControls();
              if (value == 'session') _showSessionControls();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delivery', child: Text('主动投递')),
              PopupMenuItem(value: 'session', child: Text('会话控制')),
            ],
          ),
        ],
      ),
      body: Row(
        children: [
          if (desktop) ...[
            SizedBox(
              width: AppLayout.conversationSidebarWidth,
              child: _ConversationSidebar(
                repository: widget.repository,
                selectedId: _conversationId,
                onSelected: (id) {
                  if (id != _conversationId) {
                    setState(() => _conversationId = id);
                  }
                },
                onCreate: () async {
                  final conversation = await widget.repository
                      .createConversation();
                  if (mounted) {
                    setState(() => _conversationId = conversation.id);
                  }
                },
                onRename: _renameConversation,
                onDelete: (conversation) async {
                  await widget.repository.deleteConversation(conversation);
                  if (conversation.id == _conversationId && mounted) {
                    setState(() => _conversationId = 'default');
                  }
                },
              ),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('消息暂时无法加载：$error')),
              data: (items) =>
                  items.isEmpty &&
                      _agentEvents.streams.isEmpty &&
                      !_agentEvents.typing
                  ? const Center(child: Text('从一句话开始。'))
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        16,
                        AppSpacing.page,
                        20,
                      ),
                      children: [
                        AgentEventsPanel(
                          store: _agentEvents,
                          onAction: _sendAgentAction,
                        ),
                        for (final message in items)
                          _MessageBubble(
                            message: message,
                            onRetry: message.syncStatus == 'pendingCreate'
                                ? () => _retryMessage(message.id)
                                : null,
                          ),
                      ],
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.compact,
                6,
                AppSpacing.compact,
                8,
              ),
              child: Column(
                children: [
                  if (_attachments.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      child: Wrap(
                        spacing: AppSpacing.tight,
                        runSpacing: 4,
                        children: [
                          for (
                            var index = 0;
                            index < _attachments.length;
                            index++
                          )
                            InputChip(
                              avatar: Icon(
                                _attachments[index].mimeType.startsWith(
                                      'image/',
                                    )
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                                size: AppIconSize.compact,
                              ),
                              label: Text(
                                _attachments[index].name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onDeleted: _sending
                                  ? null
                                  : () => setState(
                                      () => _attachments.removeAt(index),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: _sending ? null : _chooseAttachment,
                        icon: const Icon(Icons.add_circle_outline, size: 28),
                        tooltip: '添加照片或文件',
                      ),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: AppColors.outline),
                          ),
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: const InputDecoration(
                              hintText: '写消息…',
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 11,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.controlGap),
                      IconButton.filled(
                        onPressed: _sending ? null : _send,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_upward),
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
        ],
      ),
    );
  }
}

class _ConversationSidebar extends StatelessWidget {
  const _ConversationSidebar({
    required this.repository,
    required this.selectedId,
    required this.onSelected,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
  });

  final ChatRepository repository;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback onCreate;
  final ValueChanged<Conversation> onRename;
  final ValueChanged<Conversation> onDelete;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.sidebar,
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: LuminaSolidSurface(
            radius: AppRadius.desktopPanel,
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 4, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '会话',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      LuminaGlassControl(
                        child: IconButton(
                          onPressed: onCreate,
                          icon: const Icon(Icons.add),
                          tooltip: '新建会话',
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: StreamBuilder<List<Conversation>>(
                    stream: repository.watchConversations(),
                    builder: (context, snapshot) {
                      final conversations =
                          snapshot.data ?? const <Conversation>[];
                      if (conversations.isEmpty) {
                        return const OrialisEmptyState(
                          text: '正在同步会话…',
                          card: false,
                        );
                      }
                      return ListView.separated(
                        itemCount: conversations.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpacing.tight),
                        itemBuilder: (context, index) {
                          final conversation = conversations[index];
                          final selected = conversation.id == selectedId;
                          return LuminaGlassControl(
                            selected: selected,
                            child: ListTile(
                              dense: true,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
                              ),
                              leading: Icon(
                                conversation.type == 'main'
                                    ? Icons.home_outlined
                                    : Icons.chat_bubble_outline,
                                size: 19,
                              ),
                              title: Text(
                                conversation.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                conversation.type == 'main'
                                    ? '主会话'
                                    : '普通会话',
                              ),
                              onTap: () => onSelected(conversation.id),
                              trailing: conversation.type == 'main'
                                  ? null
                                  : PopupMenuButton<String>(
                                      tooltip: '会话操作',
                                      onSelected: (action) {
                                        if (action == 'rename') {
                                          onRename(conversation);
                                        } else if (action == 'delete') {
                                          onDelete(conversation);
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text('重命名'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('删除'),
                                        ),
                                      ],
                                    ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onRetry});
  final Message message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final attachments = _decodeAttachments(message.attachmentsJson);
    return OrialisChatBubble(
      isUser: isUser,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.content.isNotEmpty)
            isUser
                ? Text(message.content)
                : SafeMarkdownView(source: message.content),
          for (final attachment in attachments)
            _AttachmentPreview(attachment: attachment),
          const SizedBox(height: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatMessageTime(message.createdAt),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.muted,
                  fontSize: 10,
                ),
              ),
              if (isUser) ...[
                const SizedBox(width: 4),
                if (message.syncStatus == 'pendingCreate')
                  TextButton(onPressed: onRetry, child: const Text('重试'))
                else
                  const Icon(Icons.done_all, size: 13, color: AppColors.accent),
              ],
            ],
          ),
        ],
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          Icon(
            mimeType.startsWith('image/')
                ? Icons.image_outlined
                : Icons.insert_drive_file_outlined,
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        8,
        AppSpacing.page,
        16,
      ),
      child: Column(
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
                child: TextField(
                  controller: _controller,
                  enabled: !_sending,
                  autofocus: true,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: '输入要交给 Hermes 的命令',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.controlGap),
              IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward),
                tooltip: '发送命令',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '结果会显示在聊天时间线中；旧服务端会安全忽略此扩展入口。',
            style: Theme.of(context).textTheme.bodySmall,
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
    setState(() => _sending = true);
    try {
      await widget.onAction(type, payload);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        8,
        AppSpacing.page,
        18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('会话控制', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.controlGap),
          Wrap(
            spacing: AppSpacing.tight,
            runSpacing: AppSpacing.tight,
            children: [
              OutlinedButton.icon(
                onPressed: _sending ? null : () => _run('session.create'),
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
              OutlinedButton.icon(
                onPressed: _sending ? null : () => _run('session.reset'),
                icon: const Icon(Icons.restart_alt),
                label: const Text('重置'),
              ),
              OutlinedButton.icon(
                onPressed: _sending ? null : () => _run('session.resume'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('恢复'),
              ),
              OutlinedButton.icon(
                onPressed: _sending ? null : () => _run('session.status'),
                icon: const Icon(Icons.info_outline),
                label: const Text('状态'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.controlGap),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _titleController,
                  enabled: !_sending,
                  decoration: const InputDecoration(hintText: '设置会话标题'),
                ),
              ),
              const SizedBox(width: AppSpacing.controlGap),
              IconButton.filled(
                onPressed: _sending
                    ? null
                    : () => _run('session.title', {
                        'title': _titleController.text.trim(),
                      }),
                icon: const Icon(Icons.check),
                tooltip: '保存标题',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '会话事件有结果时会显示在聊天时间线中。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
