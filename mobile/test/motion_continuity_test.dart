import 'package:flutter/material.dart' show NavigationDestination;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/design/mobile_motion.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';

Widget _host(Widget child, {bool reduced = false, bool neumorphic = false}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: LuminaTheme(
          highPerformanceMode: true,
          data: LuminaThemeData(neumorphic: neumorphic),
          child: DefaultTextStyle(style: const TextStyle(), child: child),
        ),
      ),
    );

void main() {
  testWidgets('segmented labels retain their current style on reversal', (
    tester,
  ) async {
    Widget view(int value) => _host(
      OrialisGlassSegmented<int>(
        items: const {0: 'Day', 1: 'Week'},
        value: value,
        onChanged: (_) {},
      ),
    );
    TextStyle style() =>
        DefaultTextStyle.of(tester.element(find.text('Week'))).style;
    await tester.pumpWidget(view(0));
    final inactive = style();
    expect(inactive.fontWeight, FontWeight.w500);
    await tester.pumpWidget(view(1));
    expect(style(), inactive);
    await tester.pump(const Duration(milliseconds: 40));
    final midway = style();
    expect(midway.color, isNot(inactive.color));
    await tester.pumpWidget(view(0));
    expect(style(), midway);
    await tester.pumpAndSettle();
    expect(style(), inactive);
    await tester.pumpWidget(view(1));
    await tester.pumpAndSettle();
    expect(style().fontWeight, FontWeight.w600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recessed navigation selection fades without changing depth', (
    tester,
  ) async {
    Widget view(int index) => _host(
      OrialisMobileNavigationOverlay(
        selectedIndex: index,
        destinations: const [
          NavigationDestination(
            icon: SizedBox(width: 24, height: 24),
            label: 'First',
          ),
          NavigationDestination(
            icon: SizedBox(width: 24, height: 24),
            label: 'Second',
          ),
        ],
        onDestinationSelected: (_) {},
        child: const SizedBox.expand(),
      ),
      neumorphic: true,
    );
    final selection = find.byKey(const ValueKey('nav-recessed-selection-1'));
    double opacity() => tester
        .widget<FadeTransition>(
          find
              .descendant(of: selection, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;
    await tester.pumpWidget(view(0));
    expect(opacity(), 0);
    await tester.pumpWidget(view(1));
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 40));
    final midway = opacity();
    expect(midway, inExclusiveRange(0, 1));
    await tester.pumpWidget(view(0));
    expect(opacity(), closeTo(midway, 1e-6));
    await tester.pumpAndSettle();
    expect(opacity(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('content fade and position continue through rapid reversal', (
    tester,
  ) async {
    Widget view(int index) => _host(
      OrialisContentTransition(
        changeKey: index,
        direction: index == 1 ? 1 : -1,
        child: const SizedBox(width: 100, height: 100),
      ),
    );
    await tester.pumpWidget(view(0));
    await tester.pumpWidget(view(1));
    await tester.pump(const Duration(milliseconds: 30));
    final opacity = tester
        .widget<FadeTransition>(find.byType(FadeTransition))
        .opacity
        .value;
    final offset = tester
        .widget<SlideTransition>(find.byType(SlideTransition))
        .position
        .value;
    expect(opacity, inExclusiveRange(.92, 1));
    await tester.pumpWidget(view(0));
    expect(
      tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value,
      closeTo(opacity, 1e-6),
    );
    expect(
      tester
          .widget<SlideTransition>(find.byType(SlideTransition))
          .position
          .value,
      offset,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value,
      1,
    );
  });

  testWidgets('reduced-motion branch fade does not restart on interruption', (
    tester,
  ) async {
    Widget view(int index) => _host(
      LuminaBranchTransition(
        index: index,
        children: const [SizedBox(), SizedBox(), SizedBox()],
      ),
      reduced: true,
    );
    await tester.pumpWidget(view(0));
    await tester.pumpWidget(view(1));
    await tester.pump(const Duration(milliseconds: 30));
    final opacity = tester
        .widget<FadeTransition>(find.byType(FadeTransition))
        .opacity
        .value;
    expect(opacity, inExclusiveRange(.96, 1));
    await tester.pumpWidget(view(2));
    expect(
      tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value,
      closeTo(opacity, 1e-6),
    );
    expect(
      tester
          .widget<SlideTransition>(find.byType(SlideTransition))
          .position
          .value,
      Offset.zero,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('navigation keeps momentum when retargeted in performance mode', (
    tester,
  ) async {
    late LuminaSpring position;
    Widget view(int index) => _host(
      Center(
        child: SizedBox(
          width: 400,
          height: 60,
          child: OrialisNavigationSelection(
            index: index,
            enabled: const [true, true, true, true, true],
            glass: false,
            onSelectionChanged: (_) {},
            builder: (animation) {
              position = animation as LuminaSpring;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(view(0));
    await tester.pumpWidget(view(4));
    await tester.pump(const Duration(milliseconds: 60));
    final before = position.value;
    final speed = position.velocity;
    expect(speed, greaterThan(0));
    await tester.pumpWidget(view(0));
    expect(position.value, closeTo(before, 1e-6));
    expect(position.velocity, closeTo(speed, 1e-6));
    await tester.pumpAndSettle();
    expect(position.value, closeTo(0, .001));
  });

  testWidgets('navigation label colors blend and retarget from current color', (
    tester,
  ) async {
    Widget view(int index) => _host(
      OrialisMobileNavigationOverlay(
        selectedIndex: index,
        destinations: const [
          NavigationDestination(
            icon: SizedBox(width: 24, height: 24),
            label: 'First',
          ),
          NavigationDestination(
            icon: SizedBox(width: 24, height: 24),
            label: 'Second',
          ),
        ],
        onDestinationSelected: (_) {},
        child: const SizedBox.expand(),
      ),
    );
    Color? color() => tester.widget<Text>(find.text('Second')).style?.color;
    await tester.pumpWidget(view(0));
    final inactive = color();
    await tester.pumpWidget(view(1));
    expect(color(), inactive);
    await tester.pump(const Duration(milliseconds: 40));
    final midway = color();
    expect(midway, isNot(inactive));
    await tester.pumpWidget(view(0));
    expect(color(), midway);
    await tester.pumpAndSettle();
    expect(color(), inactive);
    expect(tester.takeException(), isNull);
  });
}
