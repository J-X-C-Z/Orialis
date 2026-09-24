import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'design_components.dart';
import 'lumina_localizations.dart';

/// Read-only text backed by Flutter's selection engine, with Lumina controls.
class LuminaSelectableText extends StatefulWidget {
  const LuminaSelectableText(this.data, {this.style, super.key});
  final String data;
  final TextStyle? style;
  @override
  State<LuminaSelectableText> createState() => _LuminaSelectableTextState();
}

class _LuminaSelectableTextState extends State<LuminaSelectableText> {
  final _focus = FocusNode();
  String _selection = '';
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectableRegion(
    focusNode: _focus,
    selectionControls: _LuminaSelectionControls(),
    onSelectionChanged: (content) => _selection = content?.plainText ?? '',
    contextMenuBuilder: (context, state) => Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LuminaButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _selection));
            state.hideToolbar();
          },
          child: Text(LuminaLocalizations.of(context).copy),
        ),
      ),
    ),
    child: Text(widget.data, style: widget.style),
  );
}

class _LuminaSelectionControls extends TextSelectionControls
    with TextSelectionHandleControls {
  @override
  Size getHandleSize(double textLineHeight) => const Size(20, 20);
  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) =>
      const Offset(10, 0);
  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: LuminaTheme.of(context).colors.accent,
        borderRadius: BorderRadius.circular(10),
      ),
    ),
  );
  @override
  Widget buildToolbar(
    BuildContext context,
    Rect globalEditableRegion,
    double textLineHeight,
    Offset selectionMidpoint,
    List<TextSelectionPoint> endpoints,
    TextSelectionDelegate delegate,
    ValueListenable<ClipboardStatus>? clipboardStatus,
    Offset? lastSecondaryTapDownPosition,
  ) => const SizedBox.shrink();
}
