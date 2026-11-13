import 'dart:async';

import 'package:lumina_ui/lumina_ui.dart';

/// Keep the shortcut recognizer inside the tooltip so holding the button
/// starts a chat rather than consuming the gesture to show its tooltip.
class ChatShortcutButton extends StatelessWidget {
  const ChatShortcutButton({
    required this.onPressed,
    required this.onDefaultChat,
    required this.tooltip,
    this.icon = LuminaIcons.add,
    super.key,
  });

  final VoidCallback? onPressed, onDefaultChat;
  final String tooltip;
  final LuminaIcons icon;

  @override
  Widget build(BuildContext context) => LuminaTooltip(
    message: tooltip,
    child: Semantics(
      onLongPressHint: '与默认设备开始新对话',
      child: GestureDetector(
        onLongPress: onDefaultChat == null
            ? null
            : () {
                unawaited(LuminaHaptics.longPress());
                onDefaultChat!();
              },
        child: LuminaFloatingActionButton(
          frosted: true,
          icon: LuminaIcon(icon),
          onPressed: onPressed,
        ),
      ),
    ),
  );
}
