import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget host(Widget child, {bool performance = true}) => m.MaterialApp(
  home: LuminaTheme(
    highPerformanceMode: performance,
    child: m.Scaffold(
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  ),
);

void expectGlassLens(WidgetTester tester) {
  expect(find.byType(LuminaCardScope), findsNothing);
  final dynamic lens = tester
      .widget<CustomPaint>(find.byKey(const ValueKey('lumina-selection-lens')))
      .painter;
  expect(lens.glass, isTrue);
  expect(lens.tint.a, lessThan(1));
  final magnifier = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
  expect(magnifier.magnificationScale, greaterThan(1));
}

void main() {
  for (final performance in [true, false]) {
    testWidgets('body glass magnifies in performance=$performance', (
      tester,
    ) async {
      var value = 0;
      await tester.pumpWidget(
        host(
          m.StatefulBuilder(
            builder: (_, update) => LuminaSegmented<int>(
              transparent: true,
              items: const {0: 'Pending', 1: 'Undated', 2: 'Done'},
              value: value,
              onChanged: (next) => update(() => value = next),
            ),
          ),
          performance: performance,
        ),
      );
      await tester.pumpAndSettle();
      expectGlassLens(tester);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(value, 2);
      expectGlassLens(tester);
    });

    testWidgets(
      'appearance follows the navigation glass in performance=$performance',
      (tester) async {
        var mode = m.ThemeMode.system;
        await tester.pumpWidget(
          host(
            m.StatefulBuilder(
              builder: (_, update) => LuminaThemeModeSelector(
                value: mode,
                onChanged: (next) => update(() => mode = next),
              ),
            ),
            performance: performance,
          ),
        );
        await tester.pumpAndSettle();
        expectGlassLens(tester);
        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        expect(mode, m.ThemeMode.dark);
        expectGlassLens(tester);
      },
    );
  }

  testWidgets('page title row is a card while body selectors remain glass', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LuminaTopBar(title: 'Events'),
            LuminaSegmented<int>(
              transparent: true,
              items: const {0: 'Pending', 1: 'Done'},
              value: 0,
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = find.byType(LuminaTopBar);
    expect(
      find.descendant(of: header, matching: find.byType(LuminaCardScope)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final paints = tester.widgetList<CustomPaint>(
      find.descendant(of: header, matching: find.byType(CustomPaint)),
    );
    for (final paint in paints) {
      if (paint.painter.runtimeType.toString() == '_LuminaMaterial') {
        final dynamic material = paint.painter;
        expect(material.glass, isFalse);
        expect(material.tint.a, 1);
      }
    }
    expect(find.byType(RawMagnifier), findsOneWidget);
  });
}
