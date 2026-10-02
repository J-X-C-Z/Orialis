import 'dart:ui' show Tristate, CheckedState, SemanticsAction;

import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(
  Widget child, {
  bool rtl = false,
  bool opaque = false,
  bool liquid = false,
}) => m.MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      disableAnimations: opaque,
      highContrast: opaque,
      textScaler: TextScaler.linear(liquid ? 1.6 : 1),
    ),
    child: LuminaTheme(
      brightness: Brightness.dark,
      reduceTransparency: opaque,
      tint: liquid ? const Color(0xFF729BBF) : null,
      data: LuminaThemeData(liquidGlass: liquid),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: m.Scaffold(body: Center(child: child)),
      ),
    ),
  ),
);

void main() {
  testWidgets('glass multi selection supports keyboard and disabled segments', (
    tester,
  ) async {
    var selected = <int>{1};
    await tester.pumpWidget(
      _host(
        m.StatefulBuilder(
          builder: (context, setState) => LuminaMultiSegmented<int>(
            segments: const [
              m.ButtonSegment(value: 1, label: Text('First')),
              m.ButtonSegment(value: 2, label: Text('Second')),
              m.ButtonSegment(
                value: 3,
                label: Text('Unavailable'),
                enabled: false,
              ),
            ],
            selected: selected,
            onSelectionChanged: (next) => setState(() => selected = next),
          ),
        ),
      ),
    );
    final firstFocus = Focus.of(tester.element(find.text('First')));
    firstFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(selected, {1, 2});
    await tester.tap(find.text('Unavailable'));
    expect(selected, {1, 2});
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(selected, {2});
    expect(find.byType(LuminaSurface), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single selection cannot clear itself and exposes selected semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var selected = <int>{1};
      await tester.pumpWidget(
        _host(
          m.StatefulBuilder(
            builder: (context, setState) => LuminaMultiSegmented<int>(
              segments: const [
                m.ButtonSegment(value: 1, label: Text('First')),
                m.ButtonSegment(value: 2, label: Text('Second')),
              ],
              selected: selected,
              multiSelectionEnabled: false,
              onSelectionChanged: (next) => setState(() => selected = next),
            ),
          ),
        ),
      );
      await tester.tap(find.text('First'));
      expect(selected, {1});
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(selected, {2});
      final node = tester.getSemantics(find.text('Second'));
      expect(
        node.getSemanticsData().flagsCollection.isSelected,
        Tristate.isTrue,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'radio group arrow keys select siblings and skip disabled radios',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var selected = 1;
      await tester.pumpWidget(
        _host(
          m.StatefulBuilder(
            builder: (context, setState) => LuminaRadioGroup<int>(
              groupValue: selected,
              onChanged: (next) => setState(() => selected = next!),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaRadio<int>(
                    value: 1,
                    groupValue: selected,
                    onChanged: (_) {},
                  ),
                  LuminaRadio<int>(
                    value: 3,
                    groupValue: selected,
                    onChanged: null,
                  ),
                  LuminaRadio<int>(
                    value: 2,
                    groupValue: selected,
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(
        tester
            .getSemantics(find.byType(m.Radio<int>).last)
            .getSemanticsData()
            .flagsCollection
            .isChecked,
        CheckedState.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected, 1);
      semantics.dispose();
    },
  );

  testWidgets('sliders retain RTL drag and disabled radio cannot select', (
    tester,
  ) async {
    var value = .5;
    var selections = 0;
    await tester.pumpWidget(
      _host(
        m.StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LuminaRadio<int>(value: 1, groupValue: 2, onChanged: null),
              LuminaRadio<int>(
                value: 2,
                groupValue: 2,
                onChanged: (_) => selections++,
              ),
              LuminaContinuousSlider(
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
              const LuminaRangeSlider(
                values: m.RangeValues(.25, .75),
                onChanged: null,
              ),
            ],
          ),
        ),
        rtl: true,
        opaque: true,
      ),
    );
    await tester.tap(find.byType(m.Radio<int>).first);
    expect(selections, 0);
    await tester.drag(find.byType(m.Slider), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(value, lessThan(.5));
    final sliderTheme = tester
        .widget<m.SliderTheme>(
          find.descendant(
            of: find.byType(LuminaContinuousSlider),
            matching: find.byType(m.SliderTheme),
          ),
        )
        .data;
    expect(sliderTheme.trackHeight, 10);
    expect(sliderTheme.thumbShape, isNot(isA<m.RoundSliderThumbShape>()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('chip keeps selection and deletion as separate actions', (
    tester,
  ) async {
    var selected = false;
    var deleted = 0;
    await tester.pumpWidget(
      _host(
        m.StatefulBuilder(
          builder: (context, setState) => LuminaChip(
            label: const Text('Tag'),
            selected: selected,
            onSelected: (next) => setState(() => selected = next),
            onDeleted: () => deleted++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tag'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    await tester.tap(find.byIcon(m.Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletion-only chip exposes enabled deletion and inert label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var deleted = 0;
    await tester.pumpWidget(
      _host(
        LuminaChip(label: const Text('Removable'), onDeleted: () => deleted++),
      ),
    );
    await tester.tap(find.text('Removable'));
    expect(deleted, 0);
    final bodyData = tester
        .getSemantics(find.byType(m.RawChip))
        .getSemanticsData();
    expect(bodyData.flagsCollection.isEnabled, isNot(Tristate.isFalse));
    final deleteData = tester
        .getSemantics(find.byIcon(m.Icons.close_rounded))
        .getSemanticsData();
    expect(deleteData.flagsCollection.isEnabled, Tristate.isTrue);
    expect(deleteData.hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.byIcon(m.Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'glass menu retains keyboard traversal, activation and dismissal',
    (tester) async {
      var activations = 0;
      late m.MenuController controller;
      await tester.pumpWidget(
        _host(
          LuminaMenuAnchor(
            menuChildren: [
              LuminaMenuItem(
                onPressed: () => activations++,
                child: const Text('Open item'),
              ),
              const LuminaMenuItem(
                onPressed: null,
                child: Text('Disabled item'),
              ),
            ],
            builder: (context, menuController, child) {
              controller = menuController;
              return LuminaButton(
                onPressed: menuController.open,
                child: const Text('Menu'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(controller.isOpen, isTrue);
      final itemFocus = Focus.of(tester.element(find.text('Open item')));
      itemFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(activations, 1);
      expect(controller.isOpen, isFalse);
      controller.open();
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Open item'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.isOpen, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('menu and tooltip overlays keep dark liquid opaque theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LuminaMenuAnchor(
              menuChildren: const [
                LuminaMenuItem(onPressed: null, child: Text('Popup item')),
              ],
              builder: (context, controller, child) => LuminaButton(
                onPressed: controller.open,
                child: const Text('Open popup'),
              ),
            ),
            const LuminaTooltip(
              message: 'Theme tooltip',
              child: Text('Tooltip target'),
            ),
          ],
        ),
        opaque: true,
        liquid: true,
      ),
    );
    await tester.tap(find.text('Open popup'));
    await tester.pumpAndSettle();
    final menuTheme = LuminaTheme.of(tester.element(find.text('Popup item')));
    expect(menuTheme.brightness, Brightness.dark);
    expect(menuTheme.data.liquidGlass, isTrue);
    expect(menuTheme.reduceTransparency, isTrue);
    expect(menuTheme.tint, const Color(0xFF729BBF));
    final menuMedia = MediaQuery.of(tester.element(find.text('Popup item')));
    expect(menuMedia.highContrast, isTrue);
    expect(menuMedia.disableAnimations, isTrue);
    expect(menuMedia.textScaler.scale(10), 16);
    tester.state<m.TooltipState>(find.byType(m.Tooltip)).ensureTooltipVisible();
    await tester.pumpAndSettle();
    final tooltipTheme = LuminaTheme.of(
      tester.element(find.text('Theme tooltip')),
    );
    expect(tooltipTheme.brightness, Brightness.dark);
    expect(tooltipTheme.data.liquidGlass, isTrue);
    expect(tooltipTheme.reduceTransparency, isTrue);
    expect(tooltipTheme.tint, const Color(0xFF729BBF));
    final tooltipMedia = MediaQuery.of(
      tester.element(find.text('Theme tooltip')),
    );
    expect(tooltipMedia.highContrast, isTrue);
    expect(tooltipMedia.disableAnimations, isTrue);
    expect(tooltipMedia.textScaler.scale(10), 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tooltip exposes its spoken message and renders glass text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const LuminaTooltip(
          message: 'A useful explanation',
          child: Text('Hover target'),
        ),
        opaque: true,
      ),
    );
    final tooltipState = tester.state<m.TooltipState>(find.byType(m.Tooltip));
    tooltipState.ensureTooltipVisible();
    await tester.pumpAndSettle();
    expect(find.text('A useful explanation'), findsOneWidget);
    expect(find.byType(LuminaSurface), findsWidgets);
    expect(
      tester
          .getSemantics(find.byType(LuminaTooltip))
          .getSemanticsData()
          .tooltip,
      'A useful explanation',
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
