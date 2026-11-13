import 'package:flutter/material.dart' show MaterialApp, Scaffold, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';
import 'package:orialis_mobile/pages/shared/navigation_glass.dart';

void main() {
  testWidgets(
    'vertical modes keep upright slots and scrub top to bottom in RTL',
    (tester) async {
      for (final floating in [false, true]) {
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
                    child: Center(
                      child: SizedBox(
                        width: 56,
                        child: StatefulBuilder(
                          builder: (context, update) =>
                              OrialisGlassSegmented<int>(
                                direction: Axis.vertical,
                                stretch: true,
                                floating: floating,
                                items: const {0: '四象限', 1: '项目', 2: '全部'},
                                value: selected,
                                onChanged: (value) =>
                                    update(() => selected = value),
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final first = tester.getCenter(find.text('四\n象\n限'));
          final last = tester.getCenter(find.text('全\n部'));
          expect(first.dx, last.dx);
          expect(last.dy - first.dy, greaterThanOrEqualTo(96));
          await tester.tap(find.text('全\n部'));
          await tester.pumpAndSettle();
          expect(selected, 2);
          final gesture = await tester.startGesture(last);
          await tester.pump(const Duration(milliseconds: 600));
          await gesture.moveTo(first);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(selected, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );

  testWidgets('floating modes have no recessed well and keep tap and drag', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      for (final direction in TextDirection.values) {
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LuminaTheme(
                brightness: brightness,
                highPerformanceMode: true,
                data: const LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: true,
                ),
                child: Directionality(
                  textDirection: direction,
                  child: StatefulBuilder(
                    builder: (context, setState) => OrialisGlassSegmented<int>(
                      floating: true,
                      items: const {0: '四象限', 1: '项目'},
                      value: selected,
                      onChanged: (value) => setState(() => selected = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LuminaGlassWell), findsNothing);
        expect(find.byType(LuminaGlassSandwich), findsNothing);
        expect(
          find.byKey(const ValueKey('lumina-selection-well')),
          findsNothing,
        );
        expect(find.byType(BackdropFilter), findsOneWidget);
        final track = tester.widget<LuminaSurface>(
          find.byKey(const ValueKey('page-segment-track')),
        );
        expect(track.frosted, isTrue);
        expect(track.depth, LuminaSurfaceDepth.raised);
        expect(
          find.byKey(const ValueKey('lumina-selection-lens')),
          findsOneWidget,
        );
        await tester.tap(find.text('项目'));
        await tester.pumpAndSettle();
        expect(selected, 1);
        final drag = await tester.startGesture(
          tester.getCenter(find.text('项目')),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await drag.moveTo(tester.getCenter(find.text('四象限')));
        await drag.up();
        await tester.pumpAndSettle();
        expect(selected, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets(
    'appearance material retains tap, drag and RTL without navigation lens',
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
        final frame = tester.getRect(
          find.byKey(const ValueKey('page-segment-track')),
        );
        expect(find.byType(OrialisNavigationGlassFrame), findsNothing);
        final lens = tester.getRect(find.byType(LuminaSlidingSelection));
        final track = tester.widget<LuminaSurface>(
          find.byKey(const ValueKey('page-segment-track')),
        );
        expect(track.depth, LuminaSurfaceDepth.raised);
        expect(track.glass, isTrue);
        expect(track.diffuseGlass, isTrue);
        expect(frame.width, 264);
        expect(lens.top, frame.top + 4);
        expect(lens.bottom, frame.bottom - 4);
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

  testWidgets(
    'page and appearance selectors share material; null clears lens',
    (tester) async {
      int? value = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LuminaTheme(
              child: StatefulBuilder(
                builder: (context, update) => Column(
                  children: [
                    LuminaThemeModeSelector(
                      value: ThemeMode.system,
                      onChanged: (_) {},
                    ),
                    OrialisGlassSegmented<int>(
                      items: const {0: '四象限', 1: '项目'},
                      value: value,
                      compact: true,
                      onChanged: (next) =>
                          update(() => value = value == next ? null : next),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final appearance = find.byType(LuminaThemeModeSelector);
      final appearanceTrack = tester.widget<LuminaSurface>(
        find
            .descendant(of: appearance, matching: find.byType(LuminaSurface))
            .first,
      );
      final pageTrack = tester.widget<LuminaSurface>(
        find.byKey(const ValueKey('page-segment-track')),
      );
      expect(pageTrack.glass, appearanceTrack.glass);
      expect(pageTrack.diffuseGlass, appearanceTrack.diffuseGlass);
      expect(pageTrack.depth, appearanceTrack.depth);
      expect(find.byType(LuminaSlidingSelection), findsNWidgets(2));
      await tester.tap(find.text('四象限'));
      await tester.pumpAndSettle();
      expect(value, isNull);
      expect(find.byType(LuminaSlidingSelection), findsOneWidget);
      await tester.tap(find.text('项目'));
      await tester.pumpAndSettle();
      expect(value, 1);
      expect(find.byType(LuminaSlidingSelection), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
