import 'package:lumina_ui/lumina_ui.dart';

/// Keep the shortcut recognizer inside the tooltip so holding the button
/// starts a chat rather than consuming the gesture to show its tooltip.
class ChatShortcutButton extends StatelessWidget {
  const ChatShortcutButton({
    required this.onPressed,
    required this.onDefaultChat,
    required this.tooltip,
    super.key,
  });

  final VoidCallback? onPressed, onDefaultChat;
  final String tooltip;

  @override
  Widget build(BuildContext context) => LuminaTooltip(
    message: tooltip,
    child: Semantics(
      onLongPressHint: '与默认设备开始新对话',
      child: GestureDetector(
        onLongPress: onDefaultChat,
        child: LuminaFloatingActionButton(
          frosted: true,
          icon: const LuminaIcon(LuminaIcons.add),
          onPressed: onPressed,
        ),
      ),
    ),
  );
}
