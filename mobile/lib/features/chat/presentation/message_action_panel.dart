import 'package:lumina_ui/lumina_ui.dart';

enum _MessageAction { reply, copy, selectText, explain }

/// Shows the four message actions next to the pressed message.
///
/// Pass a context from the message row (for example, from a Builder around the
/// bubble), rather than the page context, so the panel follows that message.
/// The selected callback runs after the panel has closed.
Future<void> showChatMessageActionPanel({
  required BuildContext context,
  required VoidCallback onReply,
  required VoidCallback onCopy,
  required VoidCallback onSelectText,
  required VoidCallback onExplain,
}) async {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return;

  final anchor = renderObject.localToGlobal(Offset.zero) & renderObject.size;
  final sourceTheme = LuminaTheme.of(context);
  final action = await showGeneralDialog<_MessageAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭消息操作',
    barrierColor: const Color(0x00000000),
    transitionDuration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, animation, secondaryAnimation) => LuminaTheme(
      brightness: sourceTheme.brightness,
      reduceTransparency: sourceTheme.reduceTransparency,
      highPerformanceMode: sourceTheme.highPerformanceMode,
      tint: sourceTheme.tint,
      data: sourceTheme.data,
      child: DefaultTextStyle(
        style: sourceTheme.textTheme.labelMedium,
        child: _MessageActionPanel(anchor: anchor),
      ),
    ),
  );

  if (!context.mounted) return;
  switch (action) {
    case _MessageAction.reply:
      onReply();
    case _MessageAction.copy:
      onCopy();
    case _MessageAction.selectText:
      onSelectText();
    case _MessageAction.explain:
      onExplain();
    case null:
      break;
  }
}

class _MessageActionPanel extends StatelessWidget {
  const _MessageActionPanel({required this.anchor});

  final Rect anchor;

  static const _width = 272.0;
  static const _height = 114.0;
  static const _edge = 8.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final width = _width.clamp(0.0, constraints.maxWidth - _edge * 2);
      final safeTop = media.padding.top + _edge;
      final safeBottom =
          constraints.maxHeight -
          (media.viewInsets.bottom > 0
              ? media.viewInsets.bottom
              : media.padding.bottom) -
          _edge;
      final above = anchor.top - _height - _gap;
      final below = anchor.bottom + _gap;
      final top = above >= safeTop
          ? above
          : below + _height <= safeBottom
          ? below
          : above.clamp(
              safeTop,
              (safeBottom - _height).clamp(safeTop, double.infinity),
            );
      final left = (anchor.center.dx - width / 2).clamp(
        _edge,
        (constraints.maxWidth - width - _edge).clamp(_edge, double.infinity),
      );

      return Stack(
        children: [
          Positioned(
            top: top,
            left: left,
            width: width,
            child: LuminaSurface(
              key: const ValueKey('message-action-panel'),
              glass: true,
              depth: LuminaSurfaceDepth.raised,
              radius: 20,
              color: LuminaTheme.of(context).colors.raisedSurface,
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _action(
                        context,
                        _MessageAction.reply,
                        '引用',
                        '回复引用',
                        LuminaIcons.arrowLeft,
                      ),
                      const SizedBox(width: 6),
                      _action(
                        context,
                        _MessageAction.copy,
                        '复制',
                        '复制文字',
                        LuminaIcons.file,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _action(
                        context,
                        _MessageAction.selectText,
                        '选字',
                        '选择文字',
                        LuminaIcons.search,
                      ),
                      const SizedBox(width: 6),
                      _action(
                        context,
                        _MessageAction.explain,
                        '解释',
                        '请 Hermes 解释',
                        LuminaIcons.sparkles,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _action(
    BuildContext context,
    _MessageAction action,
    String caption,
    String accessibleLabel,
    LuminaIcons icon,
  ) => Expanded(
    child: Semantics(
      label: accessibleLabel,
      button: true,
      onTap: () => Navigator.of(context, rootNavigator: true).pop(action),
      child: ExcludeSemantics(
        child: LuminaButton(
          primary: false,
          onPressed: () =>
              Navigator.of(context, rootNavigator: true).pop(action),
          icon: LuminaIcon(icon, size: 17),
          child: Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ),
  );
}
