import 'dart:ui' show Tristate;

import 'package:flutter/material.dart' show NavigationDestination;
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
  bool disableAnimations = false,
  bool reduceTransparency = false,
}) async {
  tester.view.physicalSize = const Size(400, 880);
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
                textScaler: const TextScaler.linear(2),
                highContrast: highContrast,
                disableAnimations: disableAnimations,
                viewInsets: EdgeInsets.only(bottom: keyboard ? 280 : 0),
              ),
              child: LuminaTheme(
                reduceTransparency: reduceTransparency,
                data: const LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: true,
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
  testWidgets(
    'glass layers share geometry and the engraving follows the drag',
    (tester) async {
      final nav = await _mount(tester);
      final recess = find.byKey(const ValueKey('nav-recess'));
      final slider = find.byKey(const ValueKey('nav-glass-slider'));
      expect(recess, findsOneWidget);
      expect(slider, findsOneWidget);
      expect(tester.getRect(recess), tester.getRect(slider));
      expect(find.byType(OrialisNavigationGlassFrame), findsOneWidget);
      expect(find.byType(OrialisNavigationGlassLens), findsOneWidget);

      final raised = _engraving(tester, 0).transform;
      expect(raised.entry(1, 1), lessThan(1));
      expect(raised.entry(1, 3), greaterThan(0));
      final drag = await tester.startGesture(
        tester.getCenter(find.text('Today')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Chat')));
      await tester.pump();
      expect(nav.selected(), 0);
      expect(tester.getRect(recess), tester.getRect(slider));
      expect(_engraving(tester, 0).transform.entry(1, 1), closeTo(1, .001));
      expect(_engraving(tester, 0).transform.entry(1, 3), closeTo(0, .001));
      expect(_engraving(tester, 2).transform.entry(1, 1), lessThan(1));
      expect(_engraving(tester, 2).transform.entry(1, 3), greaterThan(0));

      await drag.up();
      await tester.pumpAndSettle();
      expect(nav.selected(), 2);
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(nav.selected(), 4);
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
      final initial = tester.getRect(find.byKey(const ValueKey('nav-recess')));
      drag = await tester.startGesture(tester.getCenter(find.text('Today')));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Chat')));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(nav.selected(), 0);
      expect(
        tester.getRect(find.byKey(const ValueKey('nav-recess'))).center,
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
      tester.getRect(find.byKey(const ValueKey('nav-recess'))),
      tester.getRect(find.byKey(const ValueKey('nav-glass-slider'))),
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
