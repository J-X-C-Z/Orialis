import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
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

class _RecordingCanvas implements ui.Canvas {
  final maskFilters = <ui.MaskFilter?>[];
  final shadowElevations = <double>[];
  final shadowImages = <ui.Image>[];
  final wellImages = <ui.Image>[];
  final shadowCenters = <ui.Rect>[];
  final shadowDestinations = <ui.Rect>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #drawPath) {
      maskFilters.add(
        (invocation.positionalArguments[1] as ui.Paint).maskFilter,
      );
    } else if (invocation.memberName == #drawShadow) {
      shadowElevations.add(invocation.positionalArguments[2] as double);
    } else if (invocation.memberName == #drawImageRect) {
      wellImages.add(invocation.positionalArguments[0] as ui.Image);
    } else if (invocation.memberName == #drawImageNine) {
      shadowImages.add(invocation.positionalArguments[0] as ui.Image);
      shadowCenters.add(invocation.positionalArguments[1] as ui.Rect);
      shadowDestinations.add(invocation.positionalArguments[2] as ui.Rect);
    }
    return null;
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final sample in [
      'raised',
      'recessed',
      'well',
      'coat',
      'liquid',
      'stroke',
      'shoulder',
      'circle',
    ]) {
      testWidgets('baked light matches normal $sample ${brightness.name}', (
        tester,
      ) async {
        final images = <List<int>>[];
        for (final performance in [false, true]) {
          final Widget material = switch (sample) {
            'well' => const LuminaGlassWell(),
            'coat' => const LuminaGlassCoat(),
            'liquid' => const LuminaSurface(
              liquidGlass: true,
              child: SizedBox.expand(),
            ),
            'stroke' => const LuminaSurface(
              glass: true,
              depth: LuminaSurfaceDepth.recessed,
              child: SizedBox.expand(),
            ),
            'shoulder' => const LuminaSurface(
              shoulder: true,
              child: SizedBox.expand(),
            ),
            'circle' => const LuminaSurface(
              radius: 999,
              child: SizedBox.expand(),
            ),
            _ => LuminaSurface(
              depth: sample == 'raised'
                  ? LuminaSurfaceDepth.raised
                  : LuminaSurfaceDepth.recessed,
              child: const SizedBox.expand(),
            ),
          };
          await tester.pumpWidget(
            _host(
              RepaintBoundary(
                key: const ValueKey('parity'),
                child: ColoredBox(
                  color: brightness == Brightness.light
                      ? const Color(0xFFECECEC)
                      : const Color(0xFF252931),
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: SizedBox(
                      width: sample == 'circle' ? 48 : 280,
                      height: sample == 'circle' ? 48 : 72,
                      child: material,
                    ),
                  ),
                ),
              ),
              performance: performance,
              brightness: brightness,
              neumorphic: !['liquid', 'stroke', 'shoulder'].contains(sample),
            ),
          );
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('parity')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            images.add(bytes!.buffer.asUint8List().toList());
            image.dispose();
          });
        }
        final errors = <int>[];
        for (var i = 0; i < images.first.length; i++) {
          if (i % 4 != 3) errors.add((images.first[i] - images.last[i]).abs());
        }
        errors.sort();
        final mean = errors.reduce((a, b) => a + b) / errors.length;
        final p99 = errors[(errors.length * .99).floor()];
        // Compare pixels, not just the existence of cached draw commands.
        expect(
          mean,
          lessThan(1.0),
          reason: '$sample RGB mean error $mean; p99 $p99',
        );
        expect(p99, lessThanOrEqualTo(8), reason: '$sample RGB p99 $p99');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('performance painting skips mask filters on recessed glass', (
    tester,
  ) async {
    final samples = <bool, Map<String, List<ui.MaskFilter?>>>{};
    final widgets = <String, Widget>{
      'recessed surface': LuminaSurface(
        depth: LuminaSurfaceDepth.recessed,
        child: const SizedBox(width: 200, height: 64),
      ),
      'glass well': const SizedBox(
        width: 240,
        height: 64,
        child: LuminaGlassWell(),
      ),
      'glass coat': const SizedBox(
        width: 240,
        height: 64,
        child: LuminaGlassCoat(),
      ),
    };

    for (final performance in [true, false]) {
      samples[performance] = {};
      for (final entry in widgets.entries) {
        await tester.pumpWidget(_host(entry.value, performance: performance));
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((paint) => paint.painter)
            .whereType<CustomPainter>()
            .first;
        final canvas = _RecordingCanvas();
        painter.paint(canvas, const ui.Size(240, 64));
        samples[performance]![entry.key] = canvas.maskFilters;
      }
    }

    for (final name in widgets.keys) {
      final performanceFilters = samples[true]![name]!;
      final normalFilters = samples[false]![name]!;

      expect(
        performanceFilters.whereType<ui.MaskFilter>(),
        isEmpty,
        reason: '$name should avoid blurred paint in performance mode',
      );
      expect(
        normalFilters.whereType<ui.MaskFilter>(),
        isNotEmpty,
        reason: '$name should retain its soft depth in normal mode',
      );
    }
  });

  testWidgets('baked well reuses its image across repeated paints', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 240, height: 64, child: LuminaGlassWell())),
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<CustomPainter>()
        .first;
    final first = _RecordingCanvas();
    final second = _RecordingCanvas();
    painter.paint(first, const Size(240, 64));
    painter.paint(second, const Size(240, 64));
    expect(first.wellImages, hasLength(1));
    expect(second.wellImages, hasLength(1));
    expect(
      identical(first.wellImages.single, second.wellImages.single),
      isTrue,
    );
    expect(second.maskFilters, isEmpty);
    expect(second.shadowImages, isEmpty);
  });

  testWidgets('recessed neumorphic shadows reuse nine-slice masks', (
    tester,
  ) async {
    Future<CustomPainter> mountPainter(bool performance) async {
      await tester.pumpWidget(
        _host(
          const LuminaSurface(
            depth: LuminaSurfaceDepth.recessed,
            child: SizedBox(width: 240, height: 64),
          ),
          performance: performance,
        ),
      );
      return tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<CustomPainter>()
          .first;
    }

    final performancePainter = await mountPainter(true);
    final narrow = _RecordingCanvas();
    final wide = _RecordingCanvas();
    performancePainter.paint(narrow, const ui.Size(240, 64));
    performancePainter.paint(wide, const ui.Size(480, 64));

    expect(narrow.shadowImages, hasLength(2));
    expect(wide.shadowImages, hasLength(2));
    for (var i = 0; i < 2; i++) {
      expect(identical(wide.shadowImages[i], narrow.shadowImages[i]), isTrue);
      expect(wide.shadowCenters[i], narrow.shadowCenters[i]);
    }
    expect(narrow.shadowDestinations, hasLength(2));
    expect(wide.shadowDestinations, hasLength(2));
    expect(narrow.maskFilters.whereType<ui.MaskFilter>(), isEmpty);
    expect(wide.maskFilters.whereType<ui.MaskFilter>(), isEmpty);

    final normalPainter = await mountPainter(false);
    final normal = _RecordingCanvas();
    normalPainter.paint(normal, const ui.Size(240, 64));
    expect(normal.shadowImages, isEmpty);
    expect(normal.maskFilters.whereType<ui.MaskFilter>(), hasLength(2));
  });

  testWidgets('raised liquid glass reuses normal soft-shadow masks', (
    tester,
  ) async {
    final samples = <bool, _RecordingCanvas>{};
    for (final performance in [true, false]) {
      await tester.pumpWidget(
        _host(
          const LuminaSurface(
            depth: LuminaSurfaceDepth.raised,
            liquidGlass: true,
            child: SizedBox(width: 200, height: 64),
          ),
          performance: performance,
          neumorphic: false,
        ),
      );
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<CustomPainter>()
          .first;
      final canvas = _RecordingCanvas();
      painter.paint(canvas, const ui.Size(240, 64));
      samples[performance] = canvas;
    }

    expect(samples[true]!.shadowElevations, isEmpty);
    expect(samples[true]!.shadowImages, hasLength(2));
    expect(samples[true]!.maskFilters.whereType<ui.MaskFilter>(), isEmpty);
    expect(samples[false]!.shadowElevations, isEmpty);
    expect(
      samples[false]!.maskFilters.whereType<ui.MaskFilter>(),
      hasLength(2),
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('opaque well omits local filter ${brightness.name}', (
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
          find.byType(ImageFiltered),
          opaque ? findsNothing : findsOneWidget,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        if (opaque) {
          final frost = tester.widget<ColoredBox>(find.byType(ColoredBox));
          expect(frost.color.a, 1);
        } else {
          expect(find.byType(ColoredBox), findsNothing);
        }
        expect(
          find.byType(CustomPaint),
          opaque ? findsOneWidget : findsNWidgets(2),
        );
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
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('Readable label'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal frost filters only its well, leaving the label sharp', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const LuminaGlassSandwich(child: Text('Sharp label')),
        performance: false,
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Sharp label'),
        matching: find.byType(ImageFiltered),
      ),
      findsNothing,
    );
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

  testWidgets('card decoration reuses shoulder measurement at same size', (
    tester,
  ) async {
    var measurements = 0;
    var afterFirstPaint = -1;
    var afterSecondPaint = -1;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) {
            final decoration = LuminaCardDecoration.of(
              context,
              shoulder: true,
              title: 'Title shelf',
            );
            final painter = decoration.createBoxPainter();
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder);
            painter.paint(
              canvas,
              ui.Offset.zero,
              const ImageConfiguration(size: ui.Size(340, 120)),
            );
            afterFirstPaint = measurements;
            painter.paint(
              canvas,
              ui.Offset.zero,
              const ImageConfiguration(size: ui.Size(340, 120)),
            );
            afterSecondPaint = measurements;
            painter.paint(
              canvas,
              ui.Offset.zero,
              const ImageConfiguration(size: ui.Size(320, 120)),
            );
            recorder.endRecording().dispose();
            painter.dispose();
            return const SizedBox();
          },
        ),
        neumorphic: false,
        textScaler: _CountingTextScaler(() => measurements++),
      ),
    );
    expect(afterFirstPaint, greaterThan(0));
    expect(afterSecondPaint, afterFirstPaint);
    expect(measurements, greaterThan(afterSecondPaint));
    expect(tester.takeException(), isNull);
  });

  testWidgets('neumorphic depth remains visible in both shadow modes', (
    tester,
  ) async {
    for (final depth in LuminaSurfaceDepth.values) {
      final images = <List<int>>[];
      for (final performance in [true, false]) {
        await tester.pumpWidget(
          _host(
            RepaintBoundary(
              key: const ValueKey('painted-card'),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: LuminaSurface(
                  depth: depth,
                  child: const SizedBox(width: 220, height: 100),
                ),
              ),
            ),
            performance: performance,
          ),
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('painted-card')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          images.add(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(images.first, isNot(images.last), reason: depth.name);
      expect(tester.takeException(), isNull);
    }
  });
}
