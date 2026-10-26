import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../../../core/attachments/attachment_bridge.dart';
import '../../../app/design/chat_symbols.dart';

/// A draft-only attachment strip. Uploads remain owned by the chat controller.
class ChatComposerAttachments extends StatelessWidget {
  const ChatComposerAttachments({
    required this.attachments,
    required this.onRemove,
    this.busy = false,
    super.key,
  });

  final List<AttachmentRecord> attachments;
  final ValueChanged<int> onRemove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final theme = LuminaTheme.of(context);
    return SingleChildScrollView(
      key: const ValueKey('chat-composer-attachments'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: LuminaSpacing.tight),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < attachments.length; index++)
            Padding(
              padding: const EdgeInsets.only(right: LuminaSpacing.tight),
              child: Dismissible(
                key: ValueKey((attachments[index].localPath, index)),
                direction: busy
                    ? DismissDirection.none
                    : DismissDirection.endToStart,
                onDismissed: (_) => onRemove(index),
                child: Container(
                  width: 248,
                  padding: const EdgeInsets.all(LuminaSpacing.tight),
                  decoration: BoxDecoration(
                    color: theme.colors.recessedSurface,
                    border: Border.all(color: theme.colors.outline),
                    borderRadius: BorderRadius.circular(
                      LuminaRadius.attachment,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AttachmentPreview(attachment: attachments[index]),
                      const SizedBox(width: LuminaSpacing.tight),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                message: attachments[index].name,
                                child: Text(
                                  attachments[index].name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_kind(attachments[index].mimeType).$1} · ${_size(attachments[index].size)}',
                                style: theme.textTheme.labelSmall,
                              ),
                              Text(switch (attachments[index].status) {
                                AttachmentStatus.pending => '待发送',
                                AttachmentStatus.uploading => '正在上传',
                                AttachmentStatus.uploaded => '已上传',
                                AttachmentStatus.failed => '上传失败',
                              }, style: theme.textTheme.labelSmall),
                            ],
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '移除 ${attachments[index].name}',
                        excludeFromSemantics: true,
                        child: LuminaIconButton(
                          key: ValueKey('chat-remove-attachment-$index'),
                          tooltip: '移除 ${attachments[index].name}',
                          onPressed: busy ? null : () => onRemove(index),
                          icon: const LuminaIcon(LuminaIcons.close, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

(String, LuminaIcons) _kind(String mime) {
  if (mime.startsWith('image/')) return ('图片', LuminaIcons.image);
  if (mime.startsWith('audio/')) return ('音频', LuminaIcons.voice);
  if (mime.startsWith('video/')) return ('视频', LuminaIcons.play);
  if (mime == 'application/pdf') return ('PDF', LuminaIcons.file);
  if (mime.startsWith('text/')) return ('文本', LuminaIcons.file);
  if (mime.contains('zip') || mime.contains('compressed')) {
    return ('压缩包', LuminaIcons.folder);
  }
  return ('文件', LuminaIcons.file);
}

String _size(int bytes) {
  if (bytes < 0) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.attachment});

  final AttachmentRecord attachment;

  @override
  Widget build(BuildContext context) {
    final icon = Center(
      child: _kind(attachment.mimeType).$2 == LuminaIcons.file
          ? const ChatSymbol(ChatSymbolKind.attachment, animated: false)
          : LuminaIcon(
              _kind(attachment.mimeType).$2,
              color: LuminaTheme.of(context).colors.muted,
            ),
    );
    final path = attachment.localPath;
    final canPreview =
        !kIsWeb &&
        const {
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/gif',
          'image/bmp',
        }.contains(attachment.mimeType) &&
        Uri.tryParse(path)?.hasScheme == false &&
        File(path).isAbsolute &&
        attachment.size >= 0 &&
        attachment.size <= 20 * 1024 * 1024;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(LuminaRadius.control),
        child: SizedBox.square(
          dimension: 48,
          child: canPreview
              ? FutureBuilder<FileStat>(
                  future: File(path).stat(),
                  builder: (context, snapshot) {
                    final stat = snapshot.data;
                    if (snapshot.connectionState != ConnectionState.done ||
                        stat == null ||
                        stat.type != FileSystemEntityType.file ||
                        stat.size > 20 * 1024 * 1024) {
                      return icon;
                    }
                    return Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: 128,
                      cacheHeight: 128,
                      errorBuilder: (_, _, _) => icon,
                    );
                  },
                )
              : icon,
        ),
      ),
    );
  }
}
