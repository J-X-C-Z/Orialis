import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/response_ui.dart';

class ResponseSvgView extends StatelessWidget {
  const ResponseSvgView({required this.item, super.key});

  final ResponseUiItem item;

  Widget _picture() => SvgPicture.string(
    item.source!,
    semanticsLabel: item.label,
    fit: BoxFit.contain,
    errorBuilder: (context, error, stackTrace) => Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LuminaSelectableText('图形暂时无法显示：${item.label}。可复制 SVG 源码。'),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(item.label, style: LuminaTheme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      // A neutral canvas keeps authored SVG colors readable in either theme.
      ColoredBox(
        color: Colors.white,
        child: SizedBox(height: 220, child: _picture()),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          LuminaButton(
            primary: false,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => Dialog.fullscreen(
                child: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(child: Text(item.label)),
                            IconButton(
                              tooltip: '关闭图形',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      const Text('双指缩放，拖动查看'),
                      Expanded(
                        child: ColoredBox(
                          color: Colors.white,
                          child: InteractiveViewer(
                            minScale: 1,
                            maxScale: 8,
                            child: SizedBox.expand(child: _picture()),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            child: const Text('放大查看'),
          ),
          LuminaButton(
            primary: false,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: item.source!));
              if (context.mounted) showLuminaToast(context, 'SVG 源码已复制');
            },
            child: const Text('复制 SVG'),
          ),
        ],
      ),
    ],
  );
}
