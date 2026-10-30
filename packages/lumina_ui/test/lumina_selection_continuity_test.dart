import 'dart:ui' as ui;

import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(
  Widget child, {
  bool hybrid = false,
  bool performance = false,
  bool reduced = false,
}) => m.MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: LuminaTheme(
      highPerformanceMode: performance,
      data: LuminaThemeData(neumorphic: true, neumorphicGlass: hybrid),
      child: m.Scaffold(body: Center(child: child)),
    ),
  ),
);

double _confirmation(WidgetTester tester) => tester
    .widget<Opacity>(
      find.byKey(const ValueKey('lumina-selection-confirmation')),
    )
    .opacity;

void main() {
  for (final hybrid in [false, true]) {
    for (final performance in [false, true]) {
      testWidgets(
        'switch confirmation reverses from its current frame: glass=$hybrid performance=$performance',
        (tester) async {
          var selected = false;
          late StateSetter update;
          await tester.pumpWidget(
            _host(
              StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return LuminaSwitch(
                    value: selected,
                    onChanged: (next) => setState(() => selected = next),
                  );
                },
              ),
              hybrid: hybrid,
              performance: performance,
            ),
          );
          await tester.pumpAndSettle();
          expect(_confirmation(tester), 0);
          update(() => selected = true);
          await tester.pump();
          expect(_confirmation(tester), 0);
          await tester.pump(const Duration(milliseconds: 40));
          final partial = _confirmation(tester);
          expect(partial, greaterThan(0));
          expect(partial, lessThan(1));
          update(() => selected = false);
          await tester.pump();
          expect(_confirmation(tester), closeTo(partial, .001));
          await tester.pump(const Duration(milliseconds: 40));
          expect(_confirmation(tester), lessThan(partial));
          await tester.pumpAndSettle();
          expect(_confirmation(tester), 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('reduced motion settles switch confirmation immediately', (
    tester,
  ) async {
    var selected = false;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LuminaSwitch(
              value: selected,
              onChanged: (next) => setState(() => selected = next),
            );
          },
        ),
        reduced: true,
      ),
    );
    update(() => selected = true);
    await tester.pump();
    expect(_confirmation(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('radio dot fades and can reverse without flashing', (
    tester,
  ) async {
    var selected = 0;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LuminaRadio<int>(
              value: 1,
              groupValue: selected,
              onChanged: (next) => setState(() => selected = next!),
            );
          },
        ),
      ),
    );
    double alpha() {
      final dot = find.byKey(const ValueKey('lumina-radio-dot'));
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: dot,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      return decoration.color!.a;
    }

    update(() => selected = 1);
    await tester.pump();
    expect(alpha(), 0);
    await tester.pump(const Duration(milliseconds: 40));
    final partial = alpha();
    expect(partial, greaterThan(0));
    expect(partial, lessThan(1));
    update(() => selected = 0);
    await tester.pump();
    expect(alpha(), closeTo(partial, .001));
    await tester.pumpAndSettle();
    expect(alpha(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion motion preserves the row state through every phase', (
    tester,
  ) async {
    var mounts = 0;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 300,
          child: LuminaCompletionList(
            children: [
              _CompletionProbe(
                key: const ValueKey('retained-row'),
                onMount: () => mounts++,
              ),
            ],
          ),
        ),
      ),
    );
    final original = tester.state(find.byType(_CompletionProbe));
    await tester.tap(find.byType(LuminaCheck));
    await tester.pump();
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.state(find.byType(_CompletionProbe)), same(original));
      expect(mounts, 1);
    }
    await tester.pumpAndSettle();
    expect(tester.widget<LuminaCheck>(find.byType(LuminaCheck)).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chip skin cross-fades without remounting its native control', (
    tester,
  ) async {
    var selected = false;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LuminaChip(
              selected: selected,
              onSelected: (value) => setState(() => selected = value),
              label: const Text('Keep native state'),
            );
          },
        ),
        hybrid: true,
        performance: true,
      ),
    );
    await tester.pumpAndSettle();
    final original = tester.state(find.byType(m.RawChip));
    update(() => selected = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final transition = find.byKey(
      const ValueKey('lumina-selection-surface-transition'),
    );
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(of: transition, matching: find.byType(FadeTransition)),
    );
    expect(
      fades.where((fade) => fade.opacity.value > 0 && fade.opacity.value < 1),
      hasLength(2),
    );
    expect(tester.state(find.byType(m.RawChip)), same(original));
    expect(find.text('Keep native state'), findsOneWidget);
    final widthBeforeReverse = tester.getSize(find.byType(m.RawChip)).width;
    update(() => selected = false);
    await tester.pump();
    expect(tester.state(find.byType(m.RawChip)), same(original));
    expect(
      tester.getSize(find.byType(m.RawChip)).width,
      closeTo(widthBeforeReverse, .01),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: transition, matching: find.byType(LuminaSurface)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider value bubble paints partial opacity during activation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 240,
          child: LuminaContinuousSlider(value: .5, onChanged: (_) {}),
        ),
      ),
    );
    final data = tester.widget<m.SliderTheme>(find.byType(m.SliderTheme)).data;
    final parent = tester.renderObject<RenderBox>(find.byType(m.Slider));
    final label = TextPainter(
      text: const TextSpan(
        text: '50',
        style: TextStyle(color: Color(0xff000000)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(label.dispose);
    Future<int> opacitySum(double activation) async {
      final recorder = ui.PictureRecorder();
      data.valueIndicatorShape!.paint(
        TestRecordingPaintingContext(ui.Canvas(recorder)),
        const Offset(150, 120),
        activationAnimation: AlwaysStoppedAnimation(activation),
        enableAnimation: const AlwaysStoppedAnimation(1),
        isDiscrete: false,
        labelPainter: label,
        parentBox: parent,
        sliderTheme: data,
        textDirection: TextDirection.ltr,
        value: .5,
        textScaleFactor: 1,
        sizeWithOverflow: const Size(800, 600),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 200);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var sum = 0;
      for (var offset = 3; offset < bytes.lengthInBytes; offset += 4) {
        sum += bytes.getUint8(offset);
      }
      image.dispose();
      picture.dispose();
      return sum;
    }

    final sums = await tester.runAsync(
      () async => [
        await opacitySum(0),
        await opacitySum(.25),
        await opacitySum(.75),
        await opacitySum(1),
      ],
    );
    expect(sums![0], 0);
    expect(sums[1], greaterThan(0));
    expect(sums[1], lessThan(sums[2]));
    expect(sums[2], lessThan(sums[3]));
    expect(tester.takeException(), isNull);
  });
}

class _CompletionProbe extends StatefulWidget {
  const _CompletionProbe({required this.onMount, super.key});
  final VoidCallback onMount;
  @override
  State<_CompletionProbe> createState() => _CompletionProbeState();
}

class _CompletionProbeState extends State<_CompletionProbe> {
  bool completed = false;
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => LuminaCheck(
    value: completed,
    onChanged: (next) => setState(() => completed = next),
  );
}
