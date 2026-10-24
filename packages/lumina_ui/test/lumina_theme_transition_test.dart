import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  const paperKey = Key('paper');
  const tintKey = Key('tint');

  Widget harness(
    ValueNotifier<Brightness> brightness, {
    bool reduced = false,
    double motionScale = 1,
  }) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder: (context, value, _) => AnimatedLuminaTheme(
          brightness: value,
          data: LuminaThemeData(motionScale: motionScale),
          child: Builder(
            builder: (context) {
              final theme = LuminaTheme.of(context);
              return ColoredBox(
                key: paperKey,
                color: theme.colors.paper,
                child: LuminaPalette(
                  palette: LuminaCardPalette.rose,
                  child: Builder(
                    builder: (context) => LuminaSurface(
                      key: tintKey,
                      color: const Color(0xFF888888),
                      child: Text(
                        'Theme',
                        style: LuminaTheme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Color paper(WidgetTester tester) =>
      tester.widget<ColoredBox>(find.byKey(paperKey)).color;
  LuminaTheme tintTheme(WidgetTester tester) =>
      LuminaTheme.of(tester.element(find.byKey(tintKey)));

  testWidgets(
    'colors, nested tint and fixed-color material transition together',
    (tester) async {
      final brightness = ValueNotifier(Brightness.light);
      addTearDown(brightness.dispose);
      await tester.pumpWidget(harness(brightness));
      final light = paper(tester);
      brightness.value = Brightness.dark;
      await tester.pump();
      expect(paper(tester), light);
      await tester.pump(const Duration(milliseconds: 80));
      final theme = tintTheme(tester);
      final progress = theme.colors.darkProgress;
      expect(progress, inExclusiveRange(0, 1));
      expect(
        paper(tester),
        Color.lerp(light, const LuminaColors(dark: true).paper, progress),
      );
      expect(theme.colors.tint, LuminaCardPalette.rose.tint);
      expect(
        theme.colors.accent,
        isNot(LuminaCardPalette.rose.colors(dark: true).accent),
      );

      final dynamic before = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .firstWhere(
            (painter) => painter.runtimeType.toString() == '_LuminaMaterial',
          );
      await tester.pump(const Duration(milliseconds: 20));
      final dynamic after = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .firstWhere(
            (painter) => painter.runtimeType.toString() == '_LuminaMaterial',
          );
      expect(after.shouldRepaint(before), isTrue);
      expect(after.colors.darkProgress, greaterThan(progress));

      await tester.pumpAndSettle();
      expect(paper(tester), const LuminaColors(dark: true).paper);
      expect(
        tintTheme(tester).colors.accent,
        LuminaCardPalette.rose.colors(dark: true).accent,
      );
      brightness.value = Brightness.light;
      await tester.pumpAndSettle();
      expect(paper(tester), light);
    },
  );

  testWidgets(
    'reversing midway starts at the current color and preserves state',
    (tester) async {
      final brightness = ValueNotifier(Brightness.light);
      addTearDown(brightness.dispose);
      await tester.pumpWidget(harness(brightness));
      final surfaceState = tester.state(find.byKey(tintKey));
      brightness.value = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final intermediate = paper(tester);
      brightness.value = Brightness.light;
      await tester.pump();
      expect(paper(tester), intermediate);
      await tester.pumpAndSettle();
      expect(paper(tester), const LuminaColors().paper);
      expect(tester.state(find.byKey(tintKey)), same(surfaceState));
    },
  );

  for (final reduced in [false, true]) {
    testWidgets('initial dark theme is immediate; reduced motion=$reduced', (
      tester,
    ) async {
      final brightness = ValueNotifier(Brightness.dark);
      addTearDown(brightness.dispose);
      await tester.pumpWidget(harness(brightness, reduced: reduced));
      expect(paper(tester), const LuminaColors(dark: true).paper);
      expect(tester.hasRunningAnimations, isFalse);
      if (reduced) {
        brightness.value = Brightness.light;
        await tester.pump();
        expect(paper(tester), const LuminaColors().paper);
        expect(tester.hasRunningAnimations, isFalse);
      }
    });
  }

  testWidgets('motionScale zero skips color interpolation', (tester) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(harness(brightness, motionScale: 0));
    brightness.value = Brightness.dark;
    await tester.pump();
    expect(paper(tester), const LuminaColors(dark: true).paper);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
