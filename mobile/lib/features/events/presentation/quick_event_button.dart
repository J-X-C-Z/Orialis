import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app.dart' show chatRepositoryProvider;
import '../../chat/presentation/chat_shortcut_button.dart';

import 'package:lumina_ui/lumina_ui.dart';

import '../../../pages/chat/chat_page.dart' show agentChatServiceProvider;
import '../../../pages/shared/page_parts.dart' show ContentStack;
import '../application/quick_event_service.dart';

final quickEventServiceProvider = Provider<QuickEventService>(
  (ref) => QuickEventService(ref.watch(agentChatServiceProvider)),
);

class QuickEventButton extends ConsumerStatefulWidget {
  const QuickEventButton({super.key});

  @override
  ConsumerState<QuickEventButton> createState() => _QuickEventButtonState();
}

class _QuickEventButtonState extends ConsumerState<QuickEventButton> {
  bool _opening = false;

  Future<void> _openDefaultChat() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final service = ref.read(agentChatServiceProvider);
      final repository = ref.read(chatRepositoryProvider);
      final identity = await service.identity();
      final device = await service.defaultDevice();
      if (await service.identity() != identity || !mounted) return;
      final remote = await service.createConversation(device);
      if (await service.identity() != identity || !mounted) return;
      final conversation = await repository.importDeviceConversation(remote);
      if (await service.identity() != identity || !mounted) return;
      context.go(
        Uri(
          path: '/chat',
          queryParameters: {'conversationId': conversation.id},
        ).toString(),
      );
    } on StateError catch (error) {
      if (mounted) showLuminaToast(context, error.message.toString());
    } catch (_) {
      if (mounted) showLuminaToast(context, '默认设备对话未能建立，请联网后重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ChatShortcutButton(
    tooltip: '用一句话让 Hermes 添加事件；长按与默认设备聊天',
    icon: LuminaIcons.sparkles,
    onDefaultChat: _opening ? null : _openDefaultChat,
    onPressed: _opening
        ? null
        : () => showLuminaSheet<void>(
            context: context,
            builder: (_) => QuickEventEditor(
              submit: ref.read(quickEventServiceProvider).submit,
              checkAvailable: ref
                  .read(quickEventServiceProvider)
                  .unavailableReason,
            ),
          ),
  );
}

class QuickEventEditor extends StatefulWidget {
  const QuickEventEditor({
    required this.submit,
    this.checkAvailable,
    super.key,
  });
  final Future<void> Function(QuickEventRequest) submit;

  /// Optional pre-flight so an offline backend is visible before typing.
  final Future<String?> Function()? checkAvailable;

  @override
  State<QuickEventEditor> createState() => _QuickEventEditorState();
}

class _QuickEventEditorState extends State<QuickEventEditor> {
  final _text = TextEditingController();
  QuickEventRequest? _request;
  bool _sending = false, _submitted = false;
  String? _error, _notice;

  @override
  void initState() {
    super.initState();
    widget.checkAvailable?.call().then((notice) {
      if (mounted && notice != null && !_submitted) {
        setState(() => _notice = notice);
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || _submitted) return;
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先写下要安排的事情');
      return;
    }
    if (_request?.text != text) _request = QuickEventRequest(text);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.submit(_request!);
      if (mounted) {
        setState(() {
          _submitted = true;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : '暂未确认提交成功，内容已保留；重试不会重复提交同一请求',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: ContentStack(
      gap: 16,
      children: [
        Text('快捷添加事件', style: LuminaTheme.of(context).textTheme.titleLarge),
        Text(
          _submitted
              ? '已提交给 Azure Hermes，等待后台处理。处理会话可在聊天中查看。'
              : '用自己的话描述，交给 Azure Hermes 安排。',
        ),
        LuminaTextField(
          controller: _text,
          label: '要安排什么？',
          hint: '例如：明天下午三点开项目会，提前十分钟提醒我',
          autofocus: true,
          maxLines: 4,
          maxLength: 10000,
          enabled: !_sending && !_submitted,
        ),
        if (_notice != null && _error == null)
          _EditorNotice(_notice!, tone: _NoticeTone.warning),
        if (_error != null) _EditorNotice(_error!, tone: _NoticeTone.danger),
        LuminaButton(
          onPressed: _sending
              ? null
              : _submitted
              ? () => Navigator.of(context).pop()
              : _submit,
          child: Text(
            _sending
                ? '正在提交…'
                : _submitted
                ? '完成'
                : '发送给后台',
          ),
        ),
      ],
    ),
  );
}

enum _NoticeTone { warning, danger }

/// Icon plus text so the state never depends on colour alone.
class _EditorNotice extends StatelessWidget {
  const _EditorNotice(this.text, {required this.tone});
  final String text;
  final _NoticeTone tone;
  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final color = tone == _NoticeTone.danger
        ? theme.colors.danger
        : theme.colors.muted;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LuminaIcon(
              tone == _NoticeTone.danger
                  ? LuminaIcons.error
                  : LuminaIcons.warning,
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
