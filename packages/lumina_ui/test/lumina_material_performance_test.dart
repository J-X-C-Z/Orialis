import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(
  Widget child, {
  bool performance = true,
  bool opaque = false,
  bool contrast = false,
  bool neumorphic = true,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(highContrast: contrast, textScaler: textScaler),
    child: LuminaTheme(
      brightness: brightness,
      highPerformanceMode: performance,
      reduceTransparency: opaque,
      data: LuminaThemeData(neumorphic: neumorphic, neumorphicGlass: true),
      child: Center(child: child),
    ),
  ),
);

class _CountingTextScaler extends TextScaler {
  const _CountingTextScaler(this.onScale);
  final VoidCallback onScale;

  @override
  double scale(double fontSize) {
    onScale();
    return fontSize;
  }

  @override
  double get textScaleFactor => 1;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('opaque well omits backdrop filter ${brightness.name}', (
      tester,
    ) async {
      for (final mode in [(true, false), (false, true), (false, false)]) {
        await tester.pumpWidget(
          _host(
            const SizedBox(width: 240, height: 64, child: LuminaGlassWell()),
            brightness: brightness,
            performance: false,
            opaque: mode.$1,
            contrast: mode.$2,
          ),
        );
        final opaque = mode.$1 || mode.$2;
        expect(
          find.byType(BackdropFilter),
          opaque ? findsNothing : findsOneWidget,
        );
        final frost = tester.widget<ColoredBox>(find.byType(ColoredBox));
        expect(frost.color.a, opaque ? 1 : closeTo(.16, .0001));
        expect(find.byType(CustomPaint), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('performance frost keeps content without per-control backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 240,
          height: 64,
          child: LuminaGlassSandwich(child: Text('Readable label')),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(LuminaGlassCoat), findsOneWidget);
    expect(find.text('Readable label'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final performance in [true, false]) {
    testWidgets('ordinary tap ticker follows performance=$performance', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          LuminaSurface(
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 64),
          ),
          performance: performance,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      final press = await tester.startGesture(
        tester.getCenter(find.byType(LuminaSurface)),
      );
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(
        tester.binding.transientCallbackCount,
        performance ? 0 : greaterThan(0),
      );
      await press.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shoulder text is measured only for a visible title shelf', (
    tester,
  ) async {
    for (final decoration in [false, true]) {
      for (final neumorphic in [true, false]) {
        for (final shoulder in [false, true]) {
          var measurements = 0;
          final scaler = _CountingTextScaler(() => measurements++);
          await tester.pumpWidget(
            _host(
              Builder(
                builder: (context) => SizedBox(
                  width: 340,
                  height: 120,
                  child: decoration
                      ? DecoratedBox(
                          decoration: LuminaCardDecoration.of(
                            context,
                            shoulder: shoulder,
                            title: 'Title shelf',
                          ),
                        )
                      : LuminaSurface(
                          shoulder: shoulder,
                          shoulderTitle: 'Title shelf',
                          child: const SizedBox(),
                        ),
                ),
              ),
              neumorphic: neumorphic,
              textScaler: scaler,
            ),
          );
          expect(measurements, shoulder && !neumorphic ? greaterThan(0) : 0);
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}
