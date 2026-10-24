import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart'
    show Material, MaterialType, MaterialPageRoute, SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:mime/mime.dart';

import '../../../app/app.dart';
import '../../../app/design/lumina_compat.dart' show OrialisPageScaffold;
import '../../../core/config/app_config.dart';
import '../../../core/network/orialis_api_client.dart';

class ChatAttachmentTile extends StatelessWidget {
  const ChatAttachmentTile({required this.attachment, super.key});
  final Map<String, dynamic> attachment;

  @override
  Widget build(BuildContext context) {
    final name = attachment['name'] as String? ?? '附件';
    final id = attachment['id'] as String?;
    final image = (attachment['mimeType'] as String? ?? '').startsWith(
      'image/',
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LuminaListRow(
        title: name,
        subtitle: id == null ? '等待上传' : '轻触预览或保存',
        leading: LuminaIcon(image ? LuminaIcons.image : LuminaIcons.file),
        onTap: id == null
            ? null
            : () => Navigator.of(context, rootNavigator: true).push<void>(
                MaterialPageRoute(
                  builder: (_) => _AttachmentPage(attachment: attachment),
                ),
              ),
      ),
    );
  }
}

class _AttachmentPage extends ConsumerStatefulWidget {
  const _AttachmentPage({required this.attachment});
  final Map<String, dynamic> attachment;
  @override
  ConsumerState<_AttachmentPage> createState() => _AttachmentPageState();
}

class _AttachmentPageState extends ConsumerState<_AttachmentPage> {
  late AppConfig _config;
  Uint8List? _bytes;
  String? _error;
  bool _invalid = false, _saving = false;
  String get _name => widget.attachment['name'] as String? ?? '附件';

  @override
  void initState() {
    super.initState();
    _config = ref.read(appConfigProvider);
    _config.addIdentityListener(_invalidate);
    unawaited(_load());
  }

  Future<void> _invalidate() async {
    _invalid = true;
    if (mounted) {
      setState(() {
        _bytes = null;
        _error = '登录已改变，请重新打开附件';
      });
    }
  }

  Future<void> _load() async {
    try {
      final client = OrialisApiClient(
        baseUrl: await _config.serverUrl(),
        deviceId: await _config.deviceId(),
        config: _config,
      );
      if (_invalid || !mounted) return;
      final bytes = await client.downloadAttachment(
        widget.attachment['id'] as String,
      );
      if (!_invalid && mounted) {
        setState(() {
          _bytes = bytes;
          _error = null;
        });
      }
    } catch (error) {
      if (!_invalid && mounted) setState(() => _error = '附件暂时无法加载：$error');
    }
  }

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null || _invalid || _saving) return;
    setState(() => _saving = true);
    try {
      final path = await FilePicker.saveFile(
        fileName: _name.replaceAll(RegExp(r'[/\\]'), '_'),
        bytes: bytes,
      );
      if (_invalid || !mounted) return;
      if (mounted && path != null) showLuminaToast(context, '附件已保存');
    } catch (error) {
      if (mounted) showLuminaToast(context, '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _config.removeIdentityListener(_invalidate);
    _bytes = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: _name,
    leading: LuminaIconButton(
      tooltip: '返回聊天',
      icon: const LuminaIcon(LuminaIcons.back),
      onPressed: () => Navigator.pop(context),
    ),
    actions: [
      LuminaIconButton(
        tooltip: '保存附件',
        icon: const LuminaIcon(LuminaIcons.file),
        onPressed: _bytes == null || _saving ? null : _save,
      ),
    ],
    body: Builder(
      builder: (context) => LuminaMaterialBridge(
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: EdgeInsets.only(
              top: LuminaPageHeaderInset.of(context) + 12,
            ),
            child: _body(),
          ),
        ),
      ),
    ),
  );

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            if (!_invalid)
              LuminaButton(
                onPressed: () {
                  setState(() => _error = null);
                  unawaited(_load());
                },
                child: const Text('重试'),
              ),
          ],
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) return const Center(child: LuminaProgress());
    final declared = widget.attachment['mimeType'] as String? ?? '';
    final mime = declared.isEmpty || declared == 'application/octet-stream'
        ? lookupMimeType(_name) ?? declared
        : declared;
    if (mime.startsWith('image/')) {
      return InteractiveViewer(
        minScale: .5,
        maxScale: 6,
        child: Center(
          child: Image.memory(
            bytes,
            errorBuilder: (_, _, _) => const Text('无法预览此图片，请保存后查看'),
          ),
        ),
      );
    }
    if (mime.startsWith('text/') ||
        mime == 'application/json' ||
        mime == 'application/xml') {
      if (bytes.length > 256 * 1024) {
        return const Center(child: Text('文件较大，请保存后查看'));
      }
      return SingleChildScrollView(
        child: SelectableText(utf8.decode(bytes, allowMalformed: true)),
      );
    }
    return Center(child: Text('$_name\n${bytes.length} 字节\n请保存到手机后打开'));
  }
}
