import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';
import 'package:orialis_mobile/pages/shared/navigation_glass.dart';

void main() {
  testWidgets(
    'compact modes retain tap, drag, RTL and housing inner-boundary geometry',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final direction in TextDirection.values) {
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LuminaTheme(
                data: const LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: true,
                ),
                child: Directionality(
                  textDirection: direction,
                  child: StatefulBuilder(
                    builder: (context, setState) => SizedBox(
                      height: 64,
                      child: OrialisGlassSegmented<int>(
                        items: const {0: '日', 1: '周', 2: '月'},
                        value: selected,
                        onChanged: (i) => setState(() => selected = i),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final frame = tester.getRect(find.byType(OrialisNavigationGlassFrame));
        final lens = tester.getRect(
          find.byKey(const ValueKey('nav-glass-slider')),
        );
        expect(frame.width, 264);
        expect(lens.top, frame.top + 7);
        expect(lens.bottom, frame.bottom - 7);
        await tester.tap(find.text('月'));
        await tester.pumpAndSettle();
        expect(selected, 2);
        final drag = await tester.startGesture(
          tester.getCenter(find.text('月')),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await drag.moveTo(tester.getCenter(find.text('日')));
        await drag.up();
        await tester.pumpAndSettle();
        expect(selected, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
