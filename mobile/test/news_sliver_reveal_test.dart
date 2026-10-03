import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/news/news_motion.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    ValueNotifier<bool> visible, {
    bool reduced = false,
    Widget? sliver,
  }) => tester.pumpWidget(
    LuminaTheme(
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, value, _) => CustomScrollView(
              slivers: [
                NewsSliverReveal(
                  key: const ValueKey('reveal'),
                  visible: value,
                  sliver:
                      sliver ??
                      const SliverToBoxAdapter(
                        child: SizedBox(
                          height: 300,
                          child: Text('revealed content'),
                        ),
                      ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  SliverGeometry geometry(WidgetTester tester) => tester
      .renderObject<RenderSliver>(
        find.byKey(const ValueKey('reveal'), skipOffstage: false),
      )
      .geometry!;

  testWidgets('extent, paint and opacity animate with standard reveal curve', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    await mount(tester, visible);
    expect(geometry(tester).scrollExtent, 0);
    visible.value = true;
    await tester.pump();
    final halfway = Duration(
      microseconds: LuminaMotion.standard.inMicroseconds ~/ 2,
    );
    await tester.pump(halfway);
    final progress = luminaEaseOut.transform(.5);
    expect(geometry(tester).scrollExtent, closeTo(300 * progress, .01));
    expect(geometry(tester).paintExtent, closeTo(300 * progress, .01));
    expect(geometry(tester).layoutExtent, closeTo(300 * progress, .01));
    expect(
      tester.widget<SliverOpacity>(find.byType(SliverOpacity)).opacity,
      closeTo(progress, .001),
    );
    await tester.pumpAndSettle();
    expect(geometry(tester).scrollExtent, 300);
    visible.dispose();
  });

  testWidgets(
    'toggle reverses from current extent and closes without hit targets',
    (tester) async {
      final visible = ValueNotifier(false);
      await mount(tester, visible);
      visible.value = true;
      await tester.pump();
      await tester.pump(
        Duration(microseconds: LuminaMotion.standard.inMicroseconds ~/ 3),
      );
      final before = geometry(tester).scrollExtent;
      visible.value = false;
      await tester.pump();
      expect(geometry(tester).scrollExtent, closeTo(before, .001));
      expect(
        tester
            .widget<SliverIgnorePointer>(find.byType(SliverIgnorePointer))
            .ignoring,
        isTrue,
      );
      var semanticChildren = 0;
      tester
          .renderObject<RenderSliver>(
            find.byKey(const ValueKey('reveal'), skipOffstage: false),
          )
          .visitChildrenForSemantics((_) => semanticChildren++);
      expect(semanticChildren, 0);
      await tester.pump(
        Duration(microseconds: LuminaMotion.standard.inMicroseconds ~/ 3),
      );
      expect(geometry(tester).scrollExtent, lessThan(before));
      await tester.pumpAndSettle();
      expect(geometry(tester).scrollExtent, 0);
      expect(geometry(tester).hitTestExtent, 0);
      visible.dispose();
    },
  );

  testWidgets('reduced motion snaps open and closed in one frame', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    await mount(tester, visible, reduced: true);
    visible.value = true;
    await tester.pump();
    expect(geometry(tester).scrollExtent, 300);
    visible.value = false;
    await tester.pump();
    expect(geometry(tester).scrollExtent, 0);
    visible.dispose();
  });

  testWidgets(
    'long lists stay lazy, with no rows built while initially collapsed',
    (tester) async {
      final visible = ValueNotifier(false);
      var built = 0;
      await mount(
        tester,
        visible,
        sliver: SliverFixedExtentList(
          itemExtent: 56,
          delegate: SliverChildBuilderDelegate((context, index) {
            built++;
            return Text('row $index');
          }, childCount: 1000),
        ),
      );
      expect(built, 0);
      visible.value = true;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(built, lessThan(40));
      expect(geometry(tester).scrollExtent, 56000);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(built, lessThan(60));
      visible.value = false;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(geometry(tester).scrollExtent, 0);
      visible.value = true;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(geometry(tester).scrollExtent, 56000);
      expect(built, lessThan(100));
      expect(tester.takeException(), isNull);
      visible.dispose();
    },
  );
}
