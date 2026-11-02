import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(Widget child, {required bool performance}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(400, 240)),
    child: LuminaTheme(
      brightness: Brightness.light,
      highPerformanceMode: performance,
      data: const LuminaThemeData(neumorphic: true),
      child: Center(child: child),
    ),
  ),
);

class _RecordingCanvas implements ui.Canvas {
  final shadowDestinations = <ui.Rect>[];
  final blurredPaths = <(ui.Rect, ui.Color)>[];
  double canvasScale = 1;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #scale) {
      canvasScale = (invocation.positionalArguments[0] as double);
    } else if (invocation.memberName == #drawImageNine) {
      final rect = invocation.positionalArguments[2] as ui.Rect;
      shadowDestinations.add(
        ui.Rect.fromLTRB(
          rect.left * canvasScale,
          rect.top * canvasScale,
          rect.right * canvasScale,
          rect.bottom * canvasScale,
        ),
      );
    } else if (invocation.memberName == #drawPath) {
      final path = invocation.positionalArguments[0] as ui.Path;
      final paint = invocation.positionalArguments[1] as ui.Paint;
      if (paint.maskFilter != null) {
        blurredPaths.add((path.getBounds(), paint.color));
      }
    }
    return null;
  }
}

void main() {
  testWidgets('raised cards cast only a lower material shadow at every size', (
    tester,
  ) async {
    for (final performance in [false, true]) {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 320,
            height: 96,
            child: LuminaSurface(
              depth: LuminaSurfaceDepth.raised,
              child: SizedBox.expand(),
            ),
          ),
          performance: performance,
        ),
      );
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .firstWhere(
            (painter) => painter?.runtimeType.toString() == '_LuminaMaterial',
          )!;
      for (final size in const [Size(320, 96), Size(72, 144), Size(180, 42)]) {
        final canvas = _RecordingCanvas();
        painter.paint(canvas, size);

        if (performance) {
          expect(canvas.shadowDestinations, hasLength(1));
          final shadow = canvas.shadowDestinations.single;
          expect(shadow.center.dx, closeTo(size.width / 2 + 1, .01));
          expect(shadow.center.dy, greaterThan(size.height / 2));
          continue;
        }

        expect(canvas.blurredPaths, hasLength(1));
        final (bounds, _) = canvas.blurredPaths.single;
        expect(bounds.top, greaterThan(0));
        expect(bounds.left, greaterThanOrEqualTo(0));
      }
    }
  });
}
