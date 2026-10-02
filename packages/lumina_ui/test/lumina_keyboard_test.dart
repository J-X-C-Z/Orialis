import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  testWidgets('Tab moves through desktop actions in order', (tester) async {
    var firstActivations = 0;
    var secondActivations = 0;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xff000000),
        builder: (context, _) => LuminaKeyboardScope(
          child: FocusScope(
            autofocus: true,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaButton(
                    onPressed: () => firstActivations++,
                    child: const Text('First'),
                  ),
                  LuminaButton(
                    onPressed: () => secondActivations++,
                    child: const Text('Second'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final firstFocus = Focus.of(tester.element(find.text('First')));
    final secondFocus = Focus.of(tester.element(find.text('Second')));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      firstFocus.hasFocus,
      isTrue,
      reason:
          'primary focus: ${FocusManager.instance.primaryFocus?.context?.widget.runtimeType}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(secondFocus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(firstActivations, 0);
    expect(secondActivations, 1);
  });

  testWidgets('keyboard scope exposes Enter and Escape callbacks', (
    tester,
  ) async {
    var enters = 0;
    var escapes = 0;
    final focus = FocusNode();
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xff000000),
        builder: (context, _) => LuminaKeyboardScope(
          onEnter: () => enters++,
          onEscape: () => escapes++,
          child: Focus(
            focusNode: focus,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(enters, 1);
    expect(escapes, 1);

    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  testWidgets('keyboard scope leaves editable Enter to the text input', (
    tester,
  ) async {
    var enters = 0;
    var submitted = 0;
    final controller = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xff000000),
        builder: (context, _) => LuminaKeyboardScope(
          onEnter: () => enters++,
          child: EditableText(
            controller: controller,
            focusNode: focus,
            style: const TextStyle(color: Color(0xff000000)),
            cursorColor: const Color(0xff000000),
            backgroundCursorColor: const Color(0xff000000),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submitted++,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'sample');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // A hardware key event is not itself a text-input action, and the scope
    // must not consume it as a form submit while an editor owns focus.
    expect(enters, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    focus.dispose();
  });
}
