import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget host(
  Widget child, {
  bool glass = true,
  bool performance = false,
  bool reduced = false,
}) => WidgetsApp(
  color: const Color(0xFFE1E4E8),
  builder: (context, _) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: LuminaTheme(
      highPerformanceMode: performance,
      data: LuminaThemeData(neumorphic: true, neumorphicGlass: glass),
      child: DefaultTextStyle(
        style: const TextStyle(fontSize: 16),
        child: Center(child: child),
      ),
    ),
  ),
);

double pressure(WidgetTester tester) {
  final values = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .where((painter) => painter.runtimeType.toString() == '_LuminaMaterial')
      .map((painter) => (painter as dynamic).pressure as double);
  return values.fold(0.0, math.max);
}

void main() {
  testWidgets(
    'disabling during a press retains the label and releases continuously',
    (tester) async {
      var enabled = true;
      var taps = 0;
      var mounts = 0;
      late StateSetter update;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return LuminaButton(
                onPressed: enabled ? () => taps++ : null,
                child: _Probe(onMount: () => mounts++),
              );
            },
          ),
        ),
      );
      final state = tester.state(find.byType(_Probe));
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(_Probe)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final partial = pressure(tester);
      expect(partial, inExclusiveRange(0, 1));
      update(() => enabled = false);
      await tester.pump();
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(pressure(tester), closeTo(partial, .00001));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(taps, 0);
      expect(pressure(tester), closeTo(0, .001));
      update(() => enabled = true);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Probe)), same(state));
      await tester.tap(find.byType(_Probe));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final glass in [false, true]) {
    for (final performance in [false, true]) {
      testWidgets(
        'press material interpolates and reverses without a jump: glass=$glass performance=$performance',
        (tester) async {
          var taps = 0;
          await tester.pumpWidget(
            host(
              LuminaSurface(
                glass: glass,
                onTap: () => taps++,
                child: const SizedBox(width: 180, height: 60),
              ),
              glass: glass,
              performance: performance,
            ),
          );
          await tester.pumpAndSettle();
          expect(pressure(tester), 0);
          final pointer = await tester.startGesture(
            tester.getCenter(find.byType(LuminaSurface).first),
          );
          await tester.pump();
          expect(
            pressure(tester),
            0,
            reason: 'Touch starts an interpolation, not a material jump.',
          );
          await tester.pump(const Duration(milliseconds: 40));
          final partial = pressure(tester);
          expect(partial, inExclusiveRange(0, 1));
          await pointer.up();
          await tester.pump();
          expect(pressure(tester), closeTo(partial, .00001));
          await tester.pump(const Duration(milliseconds: 32));
          final interrupted = pressure(tester);
          final second = await tester.startGesture(
            tester.getCenter(find.byType(LuminaSurface).first),
          );
          await tester.pump();
          expect(pressure(tester), closeTo(interrupted, .00001));
          await tester.pumpAndSettle();
          expect(pressure(tester), closeTo(1, .001));
          await second.up();
          await tester.pump();
          expect(pressure(tester), closeTo(1, .001));
          await tester.pump(const Duration(milliseconds: 40));
          expect(pressure(tester), inExclusiveRange(0, 1));
          await tester.pumpAndSettle();
          expect(pressure(tester), closeTo(0, .001));
          expect(taps, 2);
          expect(tester.binding.transientCallbackCount, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a stateful label survives the first press and every release', (
    tester,
  ) async {
    var mounts = 0;
    await tester.pumpWidget(
      host(
        LuminaSurface(
          glass: true,
          onTap: () {},
          child: _Probe(onMount: () => mounts++),
        ),
      ),
    );
    final state = tester.state(find.byType(_Probe));
    for (var i = 0; i < 3; i++) {
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(_Probe)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.state(find.byType(_Probe)), same(state));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Probe)), same(state));
    }
    expect(mounts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag cancellation releases a press without firing the action', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        LuminaSurface(
          onTap: () => taps++,
          child: const SizedBox(width: 180, height: 60),
        ),
      ),
    );
    final pointer = await tester.startGesture(
      tester.getCenter(find.byType(LuminaSurface).first),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final partial = pressure(tester);
    await pointer.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(pressure(tester), closeTo(partial, .00001));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(pressure(tester), closeTo(0, .001));
    expect(taps, 0);
  });

  testWidgets(
    'reduced motion avoids displacement and settles the material directly',
    (tester) async {
      await tester.pumpWidget(
        host(
          LuminaSurface(
            glass: true,
            onTap: () {},
            child: const SizedBox(width: 180, height: 60),
          ),
          reduced: true,
        ),
      );
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(LuminaSurface).first),
      );
      await tester.pump();
      expect(pressure(tester), 1);
      for (final transform in tester.widgetList<Transform>(
        find.byType(Transform),
      )) {
        expect(transform.transform.entry(0, 0), 1);
        expect(transform.transform.entry(1, 1), 1);
        expect(transform.transform.getTranslation().length, 0);
      }
      await pointer.up();
      await tester.pumpAndSettle();
      expect(pressure(tester), 0);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 180, height: 60, child: Text('Keep state'));
}
