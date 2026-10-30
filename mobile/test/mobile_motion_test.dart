import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/design/mobile_motion.dart';

Widget host(Widget child, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: LuminaTheme(child: child),
  ),
);

void main() {
  testWidgets('short lists bounce at both edges and settle', (tester) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      host(
        OrialisMobileMotionScope(
          child: ListView(
            controller: scroll,
            children: const [SizedBox(height: 50)],
          ),
        ),
      ),
    );
    for (final delta in [160.0, -160.0]) {
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(Offset(0, delta));
      await tester.pump();
      expect(scroll.offset * delta, lessThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scroll.offset.abs(), lessThan(1));
    }
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
    'interrupted changes retain subtree and reduced motion removes translation',
    (tester) async {
      final key = GlobalKey();
      Widget view(int value, {bool reduced = false}) => host(
        OrialisContentTransition(
          changeKey: value,
          direction: 1,
          child: SizedBox(key: key, width: 100, height: 100),
        ),
        reduced: reduced,
      );
      await tester.pumpWidget(view(0));
      final element = key.currentContext;
      await tester.pumpWidget(view(1));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(view(2));
      expect(key.currentContext, same(element));
      await tester.pumpWidget(view(3, reduced: true));
      expect(
        tester
            .widget<SlideTransition>(find.byType(SlideTransition))
            .position
            .value,
        Offset.zero,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
