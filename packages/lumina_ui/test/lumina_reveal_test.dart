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
                  child: _TickProbe(key: probeKey),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(visible: true));
    await tester.pump(const Duration(milliseconds: 100));
    final state = probeKey.currentState!;
    expect(state.ticks, greaterThan(0));

    await tester.pumpWidget(host(visible: false));
    await tester.pump(LuminaMotion.standard + const Duration(milliseconds: 1));
    await tester.pump();
    final hiddenTicks = state.ticks;
    await tester.pump(const Duration(seconds: 1));
    expect(state.ticks, hiddenTicks);
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
}
