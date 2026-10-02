import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Adds desktop form and dismissal callbacks while preserving normal focus
/// traversal and text editing behavior for descendants.
///
/// Enter is observed only when a focused child has not already handled it.
/// Editable controls keep their native submit behavior. Tab traversal remains
/// Flutter's standard focus traversal.
class LuminaKeyboardScope extends StatelessWidget {
  const LuminaKeyboardScope({
    required this.child,
    this.onEnter,
    this.onEscape,
    super.key,
  });

  final Widget child;
  final VoidCallback? onEnter;
  final VoidCallback? onEscape;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape && onEscape != null) {
        onEscape!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter && onEnter != null) {
        // Enter in a text editor belongs to its input-action configuration.
        // Do not reinterpret a hardware key event as a form-level submit when
        // the text input has not emitted an action.
        final primaryWidget =
            FocusManager.instance.primaryFocus?.context?.widget;
        if (primaryWidget is EditableText) {
          return KeyEventResult.ignored;
        }
        onEnter!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}
