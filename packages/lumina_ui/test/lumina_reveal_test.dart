import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

class _TickProbe extends StatefulWidget {
  const _TickProbe({super.key});

  @override
  State<_TickProbe> createState() => _TickProbeState();
}

class _TickProbeState extends State<_TickProbe>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  var ticks = 0;

  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) => ticks++)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 50);
}

void main() {
  testWidgets('reveal pauses hidden tickers and retains child state', (
    tester,
  ) async {
    final probeKey = GlobalKey<_TickProbeState>();
    var childBuilds = 0;
    Widget host({required bool visible, bool ancestorEnabled = true}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: LuminaTheme(
              child: TickerMode(
                enabled: ancestorEnabled,
                child: LuminaReveal(
                  visible: visible,
                  child: Builder(
                    builder: (context) {
                      childBuilds++;
                      return _TickProbe(key: probeKey);
                    },
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(visible: true));
    await tester.pump(const Duration(milliseconds: 100));
    final state = probeKey.currentState!;
    expect(state.ticks, greaterThan(0));
    expect(childBuilds, greaterThan(0));

    await tester.pumpWidget(host(visible: false));
    final buildsAtCollapseStart = childBuilds;
    await tester.pump(const Duration(milliseconds: 100));
    expect(childBuilds, buildsAtCollapseStart);
    await tester.pump(LuminaMotion.standard + const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final hiddenTicks = state.ticks;
    final hiddenBuilds = childBuilds;
    await tester.pump(const Duration(seconds: 1));
    expect(state.ticks, hiddenTicks);
    expect(childBuilds, hiddenBuilds);
    expect(find.byType(_TickProbe), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(probeKey.currentState, same(state));

    await tester.pumpWidget(host(visible: true));
    await tester.pump(LuminaMotion.standard);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.ticks, greaterThan(hiddenTicks));
    expect(probeKey.currentState, same(state));

    await tester.pumpWidget(host(visible: true, ancestorEnabled: false));
    await tester.pump();
    final disabledTicks = state.ticks;
    await tester.pump(const Duration(seconds: 1));
    expect(state.ticks, disabledTicks);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reveal reverses from its current extent when interrupted', (
    tester,
  ) async {
    Widget host(bool visible) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: LuminaTheme(
          child: Center(
            child: LuminaReveal(
              visible: visible,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(false));
    expect(tester.getSize(find.byType(LuminaReveal)).height, 0);
    await tester.pumpWidget(host(true));
    await tester.pump(const Duration(milliseconds: 100));
    final beforeReverse = tester.getSize(find.byType(LuminaReveal)).height;
    expect(beforeReverse, greaterThan(0));
    expect(beforeReverse, lessThan(100));

    await tester.pumpWidget(host(false));
    await tester.pump(const Duration(milliseconds: 1));
    final afterReverse = tester.getSize(find.byType(LuminaReveal)).height;
    expect(afterReverse, greaterThan(0));
    expect(afterReverse, lessThanOrEqualTo(beforeReverse));

    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(LuminaReveal)).height, 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion changes reveal immediately and retains child', (
    tester,
  ) async {
    final probeKey = GlobalKey<_TickProbeState>();
    Widget host(bool visible) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: LuminaTheme(
          child: Center(
            child: LuminaReveal(
              visible: visible,
              child: _TickProbe(key: probeKey),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(false));
    final state = probeKey.currentState!;
    expect(tester.getSize(find.byType(LuminaReveal)).height, 0);
    await tester.pumpWidget(host(true));
    expect(tester.getSize(find.byType(LuminaReveal)).height, 50);
    expect(probeKey.currentState, same(state));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsed reveal accepts child updates before showing', (
    tester,
  ) async {
    Widget host(bool visible, String label) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: LuminaTheme(
          child: LuminaReveal(visible: visible, child: Text(label)),
        ),
      ),
    );

    await tester.pumpWidget(host(false, 'old content'));
    expect(find.text('old content'), findsNothing);
    await tester.pumpWidget(host(false, 'updated content'));
    expect(find.text('updated content'), findsNothing);
    await tester.pumpWidget(host(true, 'updated content'));
    await tester.pumpAndSettle();
    expect(find.text('updated content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
