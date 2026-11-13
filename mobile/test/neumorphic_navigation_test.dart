import 'dart:ui' show Tristate;

import 'package:flutter/material.dart' show NavigationDestination;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:orialis_mobile/pages/shared/navigation_glass.dart';

const _names = ['Today', 'Tasks', 'Chat', 'Plan', 'Me'];

Future<({int Function() selected, ValueChanged<bool> setKeyboard})> _mount(
  WidgetTester tester, {
  TextDirection direction = TextDirection.ltr,
  int? disabledIndex,
  bool highContrast = false,
  bool highPerformance = true,
  bool disableAnimations = false,
  bool reduceTransparency = false,
  double width = 400,
  double textScale = 2,
  double bottomInset = 0,
  bool neumorphic = true,
  bool glass = true,
  ValueChanged<int>? onDragEnd,
}) async {
  tester.view.physicalSize = Size(width, 880);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var selected = 0;
  var keyboard = false;
  late StateSetter update;
  await tester.pumpWidget(
    WidgetsApp(
      color: const Color(0xFFE0E0E0),
      builder: (context, _) => StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return Directionality(
            textDirection: direction,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                padding: EdgeInsets.only(bottom: bottomInset),
                highContrast: highContrast,
                disableAnimations: disableAnimations,
                viewInsets: EdgeInsets.only(bottom: keyboard ? 280 : 0),
              ),
              child: LuminaTheme(
                highPerformanceMode: highPerformance,
                reduceTransparency: reduceTransparency,
                data: LuminaThemeData(
                  neumorphic: neumorphic,
                  neumorphicGlass: glass,
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(fontSize: 15),
                  child: OrialisMobileNavigationOverlay(
                    selectedIndex: selected,
                    destinations: [
                      for (var i = 0; i < _names.length; i++)
                        NavigationDestination(
                          icon: const SizedBox(height: 24),
                          label: _names[i],
                          enabled: i != disabledIndex,
                        ),
                    ],
                    onDestinationSelected: (value) =>
                        setState(() => selected = value),
                    onDragEnd: onDragEnd == null
                        ? null
                        : (value) {
                            onDragEnd(value);
                            setState(() => selected = value);
                          },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    selected: () => selected,
    setKeyboard: (value) => update(() => keyboard = value),
  );
}

Transform _engraving(WidgetTester tester, int index) =>
    tester.widget<Transform>(find.byKey(ValueKey('nav-engraving-$index')));

void main() {
  for (final style in ['glass', 'recessed', 'classic']) {
    testWidgets('$style navigation ticks once per tap or drag selection', (
      tester,
    ) async {
      var ticks = 0;
      var dragCommits = 0;
      final previousHandler = LuminaHaptics.effectHandler;
      LuminaHaptics.effectHandler = (effect) async {
        if (effect == 'selection') ticks++;
      };
      addTearDown(() => LuminaHaptics.effectHandler = previousHandler);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate' &&
              call.arguments == 'HapticFeedbackType.selectionClick') {
            ticks++;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final nav = await _mount(
        tester,
        disabledIndex: 4,
        neumorphic: style != 'classic',
        glass: style == 'glass',
        onDragEnd: (_) => dragCommits++,
      );
      expect(ticks, 0);
      await tester.tap(find.text('Today'));
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(ticks, 0);
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(nav.selected(), 1);
      expect(ticks, 1);
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(ticks, 1);

      Future<void> drag({bool cancel = false, String target = 'Chat'}) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Tasks')),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(tester.getCenter(find.text(target)));
        await tester.pump();
        expect(ticks, 1);
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pumpAndSettle();
      }

      await drag(cancel: true);
      await drag(target: 'Tasks');
      expect(nav.selected(), 1);
      expect(ticks, 1);
      if (style != 'classic') {
        await drag(target: 'Me');
        expect(nav.selected(), 1);
        expect(ticks, 1);
      }
      dragCommits = 0;
      await drag();
      expect(nav.selected(), 2);
      expect(dragCommits, 1);
      expect(ticks, 2);
      await tester.pumpAndSettle();
      expect(ticks, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unavailable haptics do not prevent navigation', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final nav = await _mount(tester);
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(nav.selected(), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation uses real frosted glass in both performance modes', (
    tester,
  ) async {
    final policy = LuminaBlurPolicy.instance;
    policy.useFlowingGlass();
    addTearDown(policy.useFlowingGlass);
    await _mount(tester, highPerformance: false);
    expect(find.byType(BackdropFilter), findsOneWidget);
    await _mount(tester);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(OrialisNavigationGlassLens), findsOneWidget);
    expect(
      tester
          .widget<OrialisNavigationGlassLens>(
            find.byType(OrialisNavigationGlassLens),
          )
          .shaderRefraction,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact chrome clears the gesture area at narrow widths and large text',
    (tester) async {
      for (final width in [320.0, 432.0]) {
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(const SizedBox());
          await _mount(tester, width: width, textScale: scale, bottomInset: 24);
          final frame = tester.getRect(
            find.byType(OrialisNavigationGlassFrame),
          );
          expect(frame.left, greaterThanOrEqualTo(16));
          expect(frame.right, lessThanOrEqualTo(width - 16));
          expect(frame.bottom, lessThanOrEqualTo(880 - 24 - 6));
          final reserved = tester
              .widget<LuminaNavigationInset>(find.byType(LuminaNavigationInset))
              .bottom;
          expect(reserved, greaterThanOrEqualTo(880 - 24 - frame.top));
          expect(find.byType(ImageFiltered), findsNothing);
          expect(find.byType(BackdropFilter), findsOneWidget);
          final lens = tester.getRect(
            find.byKey(const ValueKey('nav-glass-slider')),
          );
          expect(lens.top, closeTo(frame.top + 7, .01));
          expect(lens.bottom, closeTo(frame.bottom - 7, .01));
          final sampling = tester.getRect(
            find.byKey(const ValueKey('nav-glass-sampling-region')),
          );
          final samplingPaint = tester.widget<ColoredBox>(
            find.byKey(const ValueKey('nav-glass-sampling-region')),
          );
          expect(samplingPaint.color.a, greaterThan(0));
          expect(samplingPaint.color.a, lessThan(.01));
          expect(sampling.top, closeTo(lens.top, .01));
          expect(sampling.bottom, closeTo(lens.bottom, .01));
          expect(sampling.left, closeTo(lens.left, .01));
          await tester.tap(find.text('Me'));
          await tester.pumpAndSettle();
          expect(
            tester
                .getRect(find.byKey(const ValueKey('nav-glass-slider')))
                .right,
            closeTo(sampling.right, .01),
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'glass layers share geometry and the engraving follows the drag',
    (tester) async {
      final nav = await _mount(tester);
      final slider = find.byKey(const ValueKey('nav-glass-slider'));
      expect(slider, findsOneWidget);
      final frame = tester.getRect(find.byType(OrialisNavigationGlassFrame));
      expect(tester.getRect(slider).left, closeTo(frame.left + 9, .01));
      expect(tester.getRect(slider).top, closeTo(frame.top + 7, .01));
      expect(tester.getRect(slider).bottom, closeTo(frame.bottom - 7, .01));
      expect(find.byType(OrialisNavigationGlassFrame), findsOneWidget);
      expect(find.byType(OrialisNavigationGlassLens), findsOneWidget);

      final originalLabel = tester.widget<Text>(find.text('Chat'));
      final raised = _engraving(tester, 0).transform;
      expect(raised.entry(0, 0), closeTo(1.035, .0001));
      expect(raised.entry(1, 1), closeTo(1.035, .0001));
      expect(raised.entry(0, 1), 0);
      expect(raised.entry(1, 0), 0);
      expect(raised.entry(1, 3), 0);
      final drag = await tester.startGesture(
        tester.getCenter(find.text('Today')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Chat')));
      await tester.pump();
      expect(nav.selected(), 0);
      expect(
        identical(originalLabel, tester.widget<Text>(find.text('Chat'))),
        isTrue,
      );
      expect(
        tester.getRect(slider).center.dx,
        closeTo(tester.getCenter(find.text('Chat')).dx, .01),
      );
      expect(_engraving(tester, 0).transform.entry(1, 1), closeTo(1, .001));
      expect(_engraving(tester, 0).transform.entry(1, 3), closeTo(0, .001));
      expect(_engraving(tester, 2).transform.entry(1, 1), greaterThan(1));
      expect(_engraving(tester, 2).transform.entry(1, 3), 0);

      await drag.up();
      await tester.pumpAndSettle();
      expect(nav.selected(), 2);
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(nav.selected(), 4);
      expect(
        _engraving(tester, 4).transform.entry(0, 0),
        closeTo(1.035, .0001),
      );
      expect(
        _engraving(tester, 4).transform.entry(1, 1),
        closeTo(1.035, .0001),
      );
      expect(tester.getRect(slider).right, closeTo(frame.right - 9, .01));
      nav.setKeyboard(true);
      await tester.pumpAndSettle();
      expect(find.text('Me').hitTestable(), findsNothing);
      nav.setKeyboard(false);
      await tester.pumpAndSettle();
      expect(find.text('Me').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'RTL drag commits logical destination and disabled drops revert',
    (tester) async {
      var nav = await _mount(tester, direction: TextDirection.rtl);
      var drag = await tester.startGesture(
        tester.getCenter(find.text('Today')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Chat')));
      await tester.pump();
      expect(nav.selected(), 0);
      await drag.up();
      await tester.pumpAndSettle();
      expect(nav.selected(), 2);

      await tester.pumpWidget(const SizedBox.shrink());
      nav = await _mount(tester, disabledIndex: 2);
      final initial = tester.getRect(
        find.byKey(const ValueKey('nav-glass-slider')),
      );
      drag = await tester.startGesture(tester.getCenter(find.text('Today')));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Chat')));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(nav.selected(), 0);
      expect(
        tester.getRect(find.byKey(const ValueKey('nav-glass-slider'))).center,
        initial.center,
      );
    },
  );

  testWidgets('cancelled drag does not select or leave the slider displaced', (
    tester,
  ) async {
    final nav = await _mount(tester);
    final initial = tester.getRect(
      find.byKey(const ValueKey('nav-glass-slider')),
    );
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Today')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await drag.moveTo(tester.getCenter(find.text('Chat')));
    await tester.pump();
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(nav.selected(), 0);
    expect(
      (tester.getRect(find.byKey(const ValueKey('nav-glass-slider'))).center -
              initial.center)
          .distance,
      lessThan(.05),
    );
  });

  testWidgets('accessibility settings preserve navigation and semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    final nav = await _mount(
      tester,
      highContrast: true,
      disableAnimations: true,
      reduceTransparency: true,
    );
    for (var i = 0; i < _names.length; i++) {
      final node = tester.getSemantics(find.text(_names[i]));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isSelected == Tristate.isTrue, i == 0);
    }
    expect(
      tester.getRect(find.byKey(const ValueKey('nav-glass-slider'))).center,
      tester.getRect(find.byKey(const ValueKey('nav-glass-slider'))).center,
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(nav.selected(), 3);
    final drag = await tester.startGesture(tester.getCenter(find.text('Plan')));
    await tester.pump(const Duration(milliseconds: 600));
    await drag.moveTo(tester.getCenter(find.text('Tasks')));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(nav.selected(), 1);
    expect(tester.takeException(), isNull);
    expect(_engraving(tester, 1).transform.entry(1, 1), 1);
    expect(_engraving(tester, 1).transform.entry(1, 3), 0);
    semantics.dispose();
  });
}
