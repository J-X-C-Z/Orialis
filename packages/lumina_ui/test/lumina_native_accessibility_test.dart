import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart' as m;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget host(Widget child) => m.MaterialApp(
  home: LuminaTheme(
    highPerformanceMode: true,
    child: m.Scaffold(
      body: FocusScope(autofocus: true, child: Center(child: child)),
    ),
  ),
);

int tapActions(SemanticsNode node) {
  var count =
      !node.isMergedIntoParent &&
          node.getSemanticsData().hasAction(SemanticsAction.tap)
      ? 1
      : 0;
  node.visitChildren((child) {
    count += tapActions(child);
    return true;
  });
  return count;
}

void main() {
  testWidgets('icon button exposes one labeled accessible action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var activations = 0;
    await tester.pumpWidget(
      host(
        LuminaIconButton(
          tooltip: 'Open details',
          icon: const m.Icon(m.Icons.info),
          onPressed: () => activations++,
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(LuminaIconButton));
    expect(
      node,
      isSemantics(
        label: 'Open details',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );
    expect(tapActions(node), 1);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(activations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 2);
    semantics.dispose();
  });

  testWidgets(
    'checkbox merges checked state and action into one semantic node',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var value = false;
      var activations = 0;
      await tester.pumpWidget(
        host(
          m.StatefulBuilder(
            builder: (context, setState) => LuminaCheck(
              value: value,
              onChanged: (next) => setState(() {
                value = next;
                activations++;
              }),
            ),
          ),
        ),
      );
      final node = tester.getSemantics(find.byType(LuminaCheck));
      expect(
        node,
        isSemantics(
          hasCheckedState: true,
          isChecked: false,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(tapActions(node), 1);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(value, isTrue);
      expect(activations, 1);
      expect(
        tester.getSemantics(find.byType(LuminaCheck)),
        isSemantics(hasCheckedState: true, isChecked: true),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(value, isFalse);
      expect(activations, 2);
      semantics.dispose();
    },
  );

  testWidgets('disabled controls expose state and skip keyboard traversal', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const disabledIcon = ValueKey('disabled-icon');
    const disabledCheck = ValueKey('disabled-check');
    const disabledSwitch = ValueKey('disabled-switch');
    const enabledSwitch = ValueKey('enabled-switch');
    const finalAction = ValueKey('final-action');
    var value = false;
    await tester.pumpWidget(
      host(
        m.StatefulBuilder(
          builder: (context, setState) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LuminaIconButton(
                key: disabledIcon,
                tooltip: 'Unavailable',
                icon: m.Icon(m.Icons.lock),
                onPressed: null,
              ),
              const LuminaCheck(
                key: disabledCheck,
                value: true,
                onChanged: null,
              ),
              const LuminaSwitch(
                key: disabledSwitch,
                value: true,
                onChanged: null,
              ),
              LuminaSwitch(
                key: enabledSwitch,
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
              LuminaIconButton(
                key: finalAction,
                tooltip: 'Next action',
                icon: const m.Icon(m.Icons.arrow_forward),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    for (final key in [disabledIcon, disabledCheck, disabledSwitch]) {
      final node = tester.getSemantics(find.byKey(key));
      expect(
        node,
        isSemantics(
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
          isFocusable: false,
        ),
      );
      expect(tapActions(node), 0);
    }
    expect(
      tester.getSemantics(find.byKey(disabledCheck)),
      isSemantics(hasCheckedState: true, isChecked: true),
    );
    expect(
      tester.getSemantics(find.byKey(disabledSwitch)),
      isSemantics(hasToggledState: true, isToggled: true),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(enabledSwitch)),
      isSemantics(isFocused: true),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.getSemantics(find.byKey(finalAction)),
      isSemantics(isFocused: true),
    );
    semantics.dispose();
  });

  testWidgets(
    'switch keyboard activation has focus feedback and preserves lens dragging',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var value = false;
      var activations = 0;
      await tester.pumpWidget(
        host(
          m.StatefulBuilder(
            builder: (context, setState) => LuminaSwitch(
              value: value,
              onChanged: (next) => setState(() {
                value = next;
                activations++;
              }),
            ),
          ),
        ),
      );
      final initial = tester.getSemantics(find.byType(LuminaSwitch));
      expect(
        initial,
        isSemantics(
          hasToggledState: true,
          isToggled: false,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(tapActions(initial), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byType(LuminaSwitch)),
        isSemantics(isFocusable: true, isFocused: true),
      );
      final ring =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(LuminaSwitch),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      final border = ring.border! as Border;
      expect(border.top.color, isNot(const Color(0x00000000)));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(activations, 1);
      expect(
        tester.getSemantics(find.byType(LuminaSwitch)),
        isSemantics(isToggled: true),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      expect(activations, 2);
      final lens = find.byKey(const ValueKey('lumina-selection-lens'));
      final hold = await tester.startGesture(tester.getCenter(lens));
      await tester.pump(const Duration(milliseconds: 600));
      await hold.moveBy(const Offset(26, 0));
      await hold.up();
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(activations, 3);
      expect(tapActions(tester.getSemantics(find.byType(LuminaSwitch))), 1);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
