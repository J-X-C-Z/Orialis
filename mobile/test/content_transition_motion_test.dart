import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/design/mobile_motion.dart';

Widget _host(Widget child) => MediaQuery(
  data: const MediaQueryData(),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: LuminaTheme(child: child),
  ),
);

void main() {
  testWidgets('content motion eases gently and retains its interrupted frame', (
    tester,
  ) async {
    Widget view(int changeKey, double direction) => _host(
      OrialisContentTransition(
        changeKey: changeKey,
        direction: direction,
        child: const SizedBox(width: 100, height: 100),
      ),
    );

    Offset offset() => tester
        .widget<SlideTransition>(find.byType(SlideTransition))
        .position
        .value;
    double opacity() => tester
        .widget<FadeTransition>(find.byType(FadeTransition))
        .opacity
        .value;

    await tester.pumpWidget(view(0, -1));
    await tester.pumpWidget(view(1, 1));
    final start = offset();
    expect(start.dx, closeTo(.018, .001));
    expect(opacity(), closeTo(.97, .001));

    await tester.pump(const Duration(milliseconds: 70));
    expect(offset().dx, greaterThan(start.dx * .7));
    expect(opacity(), inExclusiveRange(.97, 1));

    final interruptedOffset = offset();
    final interruptedOpacity = opacity();
    await tester.pumpWidget(view(2, -1));
    expect(offset().dx, closeTo(interruptedOffset.dx, 1e-6));
    expect(offset().dy, closeTo(interruptedOffset.dy, 1e-6));
    expect(opacity(), closeTo(interruptedOpacity, 1e-6));

    await tester.pumpAndSettle();
    expect(offset(), Offset.zero);
    expect(opacity(), 1);
    expect(tester.takeException(), isNull);
  });
}
