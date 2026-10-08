import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart' as m;
import 'package:flutter/rendering.dart' show RenderEditable;
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

  testWidgets('text field exposes one actionable semantic text node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final enabledController = TextEditingController(text: 'seed');
    final enabledFocus = FocusNode();
    final disabledController = TextEditingController(text: 'locked');
    final disabledFocus = FocusNode();
    final readOnlyController = TextEditingController(text: 'read-only');
    final readOnlyFocus = FocusNode();
    final limitedController = TextEditingController();
    final limitedFocus = FocusNode();
    await tester.pumpWidget(
      host(
        Column(
          children: [
            LuminaTextField(
              key: const ValueKey('enabled-probe'),
              controller: enabledController,
              focusNode: enabledFocus,
              label: 'Probe',
            ),
            LuminaTextField(
              key: const ValueKey('disabled-probe'),
              controller: disabledController,
              focusNode: disabledFocus,
              label: 'Disabled Probe',
              enabled: false,
            ),
            LuminaTextField(
              key: const ValueKey('read-only-probe'),
              controller: readOnlyController,
              focusNode: readOnlyFocus,
              label: 'Read Only Probe',
              readOnly: true,
            ),
            LuminaTextField(
              key: const ValueKey('limited-probe'),
              controller: limitedController,
              focusNode: limitedFocus,
              label: 'Limited Probe',
              maxLength: 5,
            ),
          ],
        ),
      ),
    );

    List<SemanticsNode> allNodes() {
      final root = tester
          .binding
          .renderViews
          .single
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!;
      final result = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        result.add(node);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(root);
      return result;
    }

    final beforeNodes = allNodes();
    // ignore: avoid_print
    print(
      'LUMINA_SEMANTICS_TREE\n'
      '${beforeNodes.map((node) => node.getSemanticsData()).join('\n')}',
    );
    final enabledNodes = beforeNodes
        .where(
          (node) =>
              node.getSemanticsData().label == 'Probe' &&
              node.getSemanticsData().value == 'seed',
        )
        .toList();
    expect(
      enabledNodes,
      hasLength(1),
      reason:
          'Expected one Probe node containing the controller seed; real tree: '
          '${beforeNodes.map((node) => node.getSemanticsData()).join(' | ')}',
    );
    final enabledNode = enabledNodes.single;
    final enabledData = enabledNode.getSemanticsData();
    // Log the framework's real semantics tree for both pre-fix and post-fix
    // runs; AX/DOM values alone are not accepted as controller evidence.
    // ignore: avoid_print
    print('LUMINA_SEMANTICS_PROBE enabled=$enabledData');
    expect(enabledData.value, 'seed');
    expect(enabledData.flagsCollection.isTextField, isTrue);
    expect(enabledData.hasAction(SemanticsAction.focus), isTrue);

    enabledNode.owner!.performAction(enabledNode.id, SemanticsAction.focus);
    await tester.pump();
    expect(enabledFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    final focusedEnabledNode = allNodes().singleWhere(
      (node) =>
          node.getSemanticsData().label == 'Probe' &&
          node.getSemanticsData().value == 'seed',
    );
    expect(
      focusedEnabledNode.getSemanticsData().hasAction(SemanticsAction.setText),
      isTrue,
    );
    focusedEnabledNode.owner!.performAction(
      focusedEnabledNode.id,
      SemanticsAction.setText,
      'real',
    );
    await tester.pump();
    expect(enabledController.text, 'real');
    expect(
      allNodes()
          .singleWhere(
            (node) =>
                node.getSemanticsData().label == 'Probe' &&
                node.getSemanticsData().value == 'real',
          )
          .getSemanticsData()
          .value,
      'real',
    );
    final renderedText = _renderEditable(
      tester.renderObject<RenderObject>(
        find.descendant(
          of: find.byKey(const ValueKey('enabled-probe')),
          matching: find.byType(EditableText),
        ),
      ),
    ).text!.toPlainText();
    expect(renderedText, 'real');
    // ignore: avoid_print
    print(
      'LUMINA_SEMANTICS_RESULT label=Probe controller=${enabledController.text} '
      'render=$renderedText focus=${enabledFocus.hasFocus} '
      'keyboard=${tester.testTextInput.isVisible}',
    );

    final disabledNode = allNodes().singleWhere(
      (node) =>
          node.getSemanticsData().label == 'Disabled Probe' &&
          node.getSemanticsData().value == 'locked',
    );
    final disabledData = disabledNode.getSemanticsData();
    // ignore: avoid_print
    print('LUMINA_SEMANTICS_PROBE disabled=$disabledData');
    expect(disabledData.value, 'locked');
    expect(disabledData.flagsCollection.isTextField, isTrue);
    expect(
      disabledData.flagsCollection.isEnabled.toString(),
      'Tristate.isFalse',
    );
    expect(disabledData.hasAction(SemanticsAction.focus), isFalse);
    expect(disabledData.hasAction(SemanticsAction.setText), isFalse);
    disabledNode.owner!.performAction(
      disabledNode.id,
      SemanticsAction.setText,
      'intrusion',
    );
    await tester.pump();
    expect(disabledController.text, 'locked');
    expect(disabledFocus.hasFocus, isFalse);
    expect(tester.takeException(), isNull);

    final readOnlyNode = allNodes().singleWhere(
      (node) =>
          node.getSemanticsData().label == 'Read Only Probe' &&
          node.getSemanticsData().value == 'read-only',
    );
    final readOnlyData = readOnlyNode.getSemanticsData();
    expect(readOnlyData.flagsCollection.isReadOnly, isTrue);
    expect(readOnlyData.hasAction(SemanticsAction.focus), isTrue);
    expect(readOnlyData.hasAction(SemanticsAction.setText), isFalse);
    readOnlyNode.owner!.performAction(
      readOnlyNode.id,
      SemanticsAction.setText,
      'intrusion',
    );
    readOnlyNode.owner!.performAction(readOnlyNode.id, SemanticsAction.focus);
    await tester.pump();
    expect(readOnlyController.text, 'read-only');
    expect(readOnlyFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);

    final limitedNode = allNodes().singleWhere(
      (node) =>
          node.getSemanticsData().label == 'Limited Probe' &&
          node.getSemanticsData().flagsCollection.isTextField,
    );
    limitedNode.owner!.performAction(limitedNode.id, SemanticsAction.focus);
    await tester.pump();
    final focusedLimitedNode = allNodes().singleWhere(
      (node) =>
          node.getSemanticsData().label == 'Limited Probe' &&
          node.getSemanticsData().flagsCollection.isTextField,
    );
    expect(
      focusedLimitedNode.getSemanticsData().hasAction(SemanticsAction.setText),
      isTrue,
    );
    focusedLimitedNode.owner!.performAction(
      focusedLimitedNode.id,
      SemanticsAction.setText,
      '123456',
    );
    await tester.pump();
    expect(limitedController.text, '12345');
    expect(
      allNodes().any(
        (node) =>
            node.getSemanticsData().label == 'Limited Probe' &&
            node.getSemanticsData().value == '12345',
      ),
      isTrue,
    );

    semantics.dispose();
    enabledController.dispose();
    disabledController.dispose();
    readOnlyController.dispose();
    limitedController.dispose();
    enabledFocus.dispose();
    disabledFocus.dispose();
    readOnlyFocus.dispose();
    limitedFocus.dispose();
  });
}

RenderEditable _renderEditable(RenderObject root) {
  RenderEditable? result;
  void visit(RenderObject child) {
    if (child is RenderEditable) {
      result = child;
    } else {
      child.visitChildren(visit);
    }
  }

  visit(root);
  return result ?? (throw TestFailure('EditableText has no RenderEditable'));
}
