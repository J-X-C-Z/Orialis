import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  test('neumorphic palette is opt-in and leaves existing defaults intact', () {
    const original = LuminaThemeData();
    const newSkin = LuminaThemeData(
      visualStyle: LuminaVisualStyle.neumorphism,
    );
    expect(original.visualStyle, LuminaVisualStyle.original);
    expect(newSkin.visualStyle, LuminaVisualStyle.neumorphism);

    const baseline = LuminaColors();
    const visual = LuminaColors(neumorphic: true);
    expect(baseline.paper, LuminaBaseColors.paper);
    expect(visual.paper, const Color(0xFFEAF0F8));
    expect(visual.raisedSurface, isNot(baseline.raisedSurface));
    expect(visual.recessedSurface, isNot(visual.raisedSurface));
  });

  testWidgets('phone style propagates from the nearest LuminaTheme', (tester) async {
    Color? paper;
    bool? neumorphic;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LuminaTheme(
          data: const LuminaThemeData(
            visualStyle: LuminaVisualStyle.neumorphism,
          ),
          child: Builder(
            builder: (context) {
              final colors = LuminaTheme.of(context).colors;
              paper = colors.paper;
              neumorphic = colors.neumorphic;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(neumorphic, isTrue);
    expect(paper, const Color(0xFFEAF0F8));
  });

  test('light and dark palettes retain readable contrast', () {
    const light = LuminaColors(neumorphic: true);
    const dark = LuminaColors(dark: true, neumorphic: true);
    expect(light.ink, isNot(light.paper));
    expect(dark.ink, isNot(dark.paper));
    expect(light.accent, isNot(dark.accent));
    expect(light.outline, isNot(dark.outline));
  });
}
