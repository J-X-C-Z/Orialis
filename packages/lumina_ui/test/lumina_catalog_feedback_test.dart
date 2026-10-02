import 'dart:ui' show Tristate;

import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(
  Widget child, {
  bool reduced = true,
  bool contrast = false,
  bool opaque = false,
  TextDirection direction = TextDirection.ltr,
}) => m.MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced, highContrast: contrast),
    child: LuminaTheme(
      reduceTransparency: opaque,
      data: const LuminaThemeData(liquidGlass: true),
      child: Directionality(
        textDirection: direction,
        child: m.Scaffold(body: Center(child: child)),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'catalog buttons expose a single enabled or disabled semantic action',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LuminaMaterialButton(
                onPressed: () {},
                child: const Text('Primary'),
              ),
              LuminaFloatingActionButton(
                onPressed: () {},
                icon: const m.Icon(m.Icons.add),
                label: const Text('Floating'),
              ),
              const LuminaMaterialButton(
                onPressed: null,
                child: Text('Disabled'),
              ),
            ],
          ),
        ),
      );
      var buttons = 0;
      void visit(SemanticsNode node) {
        if (!node.isMergedIntoParent &&
            node.getSemanticsData().flagsCollection.isButton) {
          buttons++;
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      for (final control in [
        find.byType(LuminaMaterialButton).first,
        find.byType(LuminaFloatingActionButton),
        find.byType(LuminaMaterialButton).last,
      ]) {
        buttons = 0;
        visit(tester.getSemantics(control));
        expect(buttons, 1);
      }
      expect(
        tester
            .getSemantics(find.text('Primary'))
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(find.text('Disabled'))
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        Tristate.isFalse,
      );
      semantics.dispose();
    },
  );

  testWidgets('all emphasis levels are keyboard actions; disabled is skipped', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final variant in LuminaButtonVariant.values)
              LuminaMaterialButton(
                variant: variant,
                onPressed: () => activations++,
                child: Text(variant.name),
              ),
            const LuminaMaterialButton(
              onPressed: null,
              child: Text('Disabled'),
            ),
          ],
        ),
      ),
    );
    for (var index = 0; index < LuminaButtonVariant.values.length; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(activations, 5);
    await tester.tap(find.text('Disabled'));
    expect(activations, 5);
    expect(find.byType(m.FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating action sizes its label and retains disabled state', (
    tester,
  ) async {
    var count = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LuminaFloatingActionButton(
              onPressed: () => count++,
              icon: const m.Icon(m.Icons.add),
              label: const Text('New item'),
              tooltip: 'Create',
            ),
            const LuminaFloatingActionButton(
              onPressed: null,
              icon: m.Icon(m.Icons.add),
              label: Text('Unavailable'),
            ),
          ],
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(LuminaFloatingActionButton).first).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('New item'));
    await tester.tap(find.text('Unavailable'));
    expect(count, 1);
    expect(find.byType(m.FloatingActionButton), findsNothing);
  });

  testWidgets('progress publishes value and settles with reduced motion', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const SizedBox(width: 220, child: LuminaLinearProgress(value: .6))),
    );
    expect(tester.getSemantics(find.byType(LuminaLinearProgress)).value, '60%');
    await tester.pumpWidget(
      _host(const SizedBox(width: 220, child: LuminaLinearProgress())),
    );
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('indeterminate animation stops when value becomes determinate', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(width: 220, child: LuminaLinearProgress()),
        reduced: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(
      _host(
        const SizedBox(width: 220, child: LuminaLinearProgress(value: 1)),
        reduced: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('badge follows directional trailing edge and exposes its count', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final direction in TextDirection.values) {
      await tester.pumpWidget(
        _host(
          const LuminaBadge(label: '7', child: SizedBox.square(dimension: 48)),
          direction: direction,
        ),
      );
      final badge = tester.getRect(find.text('7'));
      final body = tester.getRect(find.byType(LuminaBadge));
      expect(
        direction == TextDirection.ltr
            ? badge.center.dx > body.center.dx
            : badge.center.dx < body.center.dx,
        isTrue,
      );
      expect(find.bySemanticsLabel('7'), findsOneWidget);
    }
    semantics.dispose();
  });

  testWidgets('opaque accessibility branches keep catalog materials opaque', (
    tester,
  ) async {
    for (final contrast in [false, true]) {
      await tester.pumpWidget(
        _host(
          LuminaMaterialButton(onPressed: () {}, child: const Text('Read me')),
          contrast: contrast,
          opaque: !contrast,
        ),
      );
      final materials = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .where(
            (painter) => painter.runtimeType.toString() == '_LuminaMaterial',
          )
          .cast<dynamic>();
      expect(
        materials.every(
          (material) => material.glass == false && material.tint.a == 1,
        ),
        isTrue,
      );
    }
  });
}
