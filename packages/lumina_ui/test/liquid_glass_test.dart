import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _harness(
  Widget child, {
  LuminaThemeData data = const LuminaThemeData(),
  Brightness brightness = Brightness.light,
  bool reduceTransparency = false,
  bool highContrast = false,
}) => WidgetsApp(
  color: const Color(0xff000000),
  builder: (context, _) => MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      disableAnimations: true,
      highContrast: highContrast,
    ),
    child: LuminaTheme(
      data: data,
      brightness: brightness,
      reduceTransparency: reduceTransparency,
      child: DefaultTextStyle(
        style: LuminaTextTheme(
          LuminaColors(dark: brightness == Brightness.dark),
          data,
        ).bodyMedium,
        child: Center(child: child),
      ),
    ),
  ),
);

List<dynamic> _materials(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .where((painter) => painter.runtimeType.toString() == '_LuminaMaterial')
    .cast<dynamic>()
    .toList();

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('liquid glass is opt-in and preserves the default material', (
    tester,
  ) async {
    final boundary = GlobalKey();
    Future<Uint8List> render(LuminaThemeData data) async {
      await tester.pumpWidget(
        _harness(
          RepaintBoundary(
            key: boundary,
            child: const ColoredBox(
              color: Color(0xffe8edf4),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: SizedBox(
                  width: 280,
                  height: 120,
                  child: LuminaSurface(
                    depth: LuminaSurfaceDepth.raised,
                    child: Text('Material'),
                  ),
                ),
              ),
            ),
          ),
          data: data,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return _pixels(tester, boundary);
    }

    expect(const LuminaThemeData().liquidGlass, isFalse);
    final original = await render(const LuminaThemeData());
    expect(_materials(tester).single.liquidGlass, isFalse);
    final disabled = await render(const LuminaThemeData(liquidGlass: false));
    expect(disabled, orderedEquals(original));
    final enabled = await render(const LuminaThemeData(liquidGlass: true));
    expect(_materials(tester).single.liquidGlass, isTrue);
    expect(enabled, isNot(orderedEquals(original)));
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name}: palette and controls retain liquid glass',
      (tester) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          _harness(
            RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: LuminaColors(dark: brightness == Brightness.dark).paper,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: LuminaPalette(
                    palette: LuminaCardPalette.ocean,
                    child: SizedBox(
                      width: 360,
                      child: LuminaSurface(
                        depth: LuminaSurfaceDepth.raised,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const LuminaSurface(
                              depth: LuminaSurfaceDepth.recessed,
                              child: Text('Task'),
                            ),
                            LuminaButton(
                              onPressed: () {},
                              child: const Text('Action'),
                            ),
                            LuminaCheck(value: true, onChanged: (_) {}),
                            LuminaSegmented<int>(
                              items: const {0: 'Today', 1: 'Week', 2: 'Month'},
                              value: 0,
                              onChanged: (_) {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            data: const LuminaThemeData(liquidGlass: true),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final materials = _materials(tester);
        expect(materials.length, greaterThanOrEqualTo(3));
        expect(
          materials.every((painter) => painter.liquidGlass == true),
          isTrue,
        );
        expect(
          materials.every(
            (painter) => painter.colors.dark == (brightness == Brightness.dark),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final highContrast in [false, true]) {
      testWidgets(
        '${brightness.name}: ${highContrast ? 'high contrast' : 'reduced transparency'} keeps glass opaque',
        (tester) async {
          await tester.pumpWidget(
            _harness(
              SizedBox(
                width: 300,
                height: 160,
                child: LuminaSurface(
                  glass: true,
                  backdrop: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Accessible surface'),
                      LuminaSegmented<int>(
                        items: const {0: 'Today', 1: 'Week'},
                        value: 0,
                        onChanged: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
              data: const LuminaThemeData(liquidGlass: true),
              brightness: brightness,
              highContrast: highContrast,
              reduceTransparency: !highContrast,
            ),
          );
          await tester.pumpAndSettle();
          final materials = _materials(tester);
          final painter = materials.first;
          expect(painter.glass, isFalse);
          expect(painter.tint.a, 1);
          expect(painter.contrast, isTrue);
          expect(materials.length, greaterThanOrEqualTo(3));
          expect(
            materials.every((material) => material.contrast == true),
            isTrue,
          );
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('liquid glass actions retain keyboard focus and activation', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      _harness(
        FocusScope(
          autofocus: true,
          child: LuminaButton(
            onPressed: () => activations++,
            child: const Text('Complete task'),
          ),
        ),
        data: const LuminaThemeData(liquidGlass: true),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.text('Complete task'))).hasFocus,
      isTrue,
    );
    expect(
      _materials(tester).any((painter) => painter.focused == true),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });
}
