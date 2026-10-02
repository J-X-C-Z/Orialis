import 'dart:ui' show Tristate;

import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget host(
  Widget child, {
  TextDirection direction = TextDirection.ltr,
  double scale = 1,
}) => m.MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Directionality(
        textDirection: direction,
        child: m.Scaffold(body: child),
      ),
    ),
  ),
);

FocusNode destinationFocus(WidgetTester tester, String label) => find
    .ancestor(of: find.text(label), matching: find.byType(Focus))
    .evaluate()
    .map((element) => element.widget as Focus)
    .firstWhere(
      (widget) => widget.onKeyEvent != null && widget.focusNode != null,
    )
    .focusNode!;

void main() {
  testWidgets('bar uses native glass, selected icons and disabled semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    var selected = 0;
    await tester.pumpWidget(
      host(
        m.StatefulBuilder(
          builder: (context, setState) => LuminaNavigationBar(
            selectedIndex: selected,
            onDestinationSelected: (index) => setState(() => selected = index),
            destinations: const [
              m.NavigationDestination(
                icon: m.Icon(m.Icons.home_outlined),
                selectedIcon: m.Icon(m.Icons.home),
                label: 'Home',
              ),
              m.NavigationDestination(
                icon: m.Icon(m.Icons.lock),
                label: 'Locked',
                enabled: false,
              ),
              m.NavigationDestination(
                icon: m.Icon(m.Icons.event),
                label: 'Events',
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(m.NavigationBar), findsNothing);
    expect(find.byIcon(m.Icons.home), findsOneWidget);
    expect(find.byIcon(m.Icons.home_outlined), findsNothing);
    expect(
      tester.getSemantics(find.text('Home')),
      isSemantics(
        label: 'Home',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        isFocusable: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('Locked')),
      isSemantics(
        label: 'Locked',
        isButton: true,
        hasSelectedState: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
        isFocusable: false,
      ),
    );
    await tester.tap(find.text('Locked'));
    await tester.pump();
    expect(selected, 0);
    await tester.tap(find.text('Events'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    semantics.dispose();
  });

  testWidgets('bar arrows skip disabled items and respect RTL', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      host(
        LuminaNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (index) => selected = index,
          destinations: const [
            m.NavigationDestination(icon: m.Icon(m.Icons.home), label: 'Home'),
            m.NavigationDestination(
              icon: m.Icon(m.Icons.lock),
              label: 'Locked',
              enabled: false,
            ),
            m.NavigationDestination(
              icon: m.Icon(m.Icons.event),
              label: 'Events',
            ),
          ],
        ),
        direction: TextDirection.rtl,
      ),
    );
    destinationFocus(tester, 'Home').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected, 2);
    expect(destinationFocus(tester, 'Events').hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(selected, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(selected, 0);
  });

  testWidgets(
    'drawer selection indexes destinations while retaining custom children',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 280,
            child: LuminaNavigationDrawer(
              selectedIndex: 0,
              onDestinationSelected: (index) => selected = index,
              children: const [
                Text('Workspace header'),
                m.NavigationDrawerDestination(
                  icon: m.Icon(m.Icons.home),
                  label: Text('Overview'),
                ),
                SizedBox(height: 20),
                Text('Workspace footer'),
                m.NavigationDrawerDestination(
                  icon: m.Icon(m.Icons.lock),
                  label: Text('Restricted'),
                  enabled: false,
                ),
                m.NavigationDrawerDestination(
                  icon: m.Icon(m.Icons.event),
                  label: Text('Calendar'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(m.NavigationDrawer), findsNothing);
      expect(find.text('Workspace header'), findsOneWidget);
      expect(find.text('Workspace footer'), findsOneWidget);
      await tester.tap(find.text('Restricted'));
      expect(selected, -1);
      await tester.tap(find.text('Calendar'));
      expect(selected, 2);
      destinationFocus(tester, 'Overview').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(selected, 2);
    },
  );

  testWidgets('rail handles disabled destinations and a short viewport', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      host(
        SizedBox(
          height: 150,
          child: LuminaNavigationRail(
            selectedIndex: selected,
            onDestinationSelected: (index) => selected = index,
            destinations: const [
              m.NavigationRailDestination(
                icon: m.Icon(m.Icons.home),
                label: Text('Overview'),
              ),
              m.NavigationRailDestination(
                icon: m.Icon(m.Icons.lock),
                label: Text('Restricted'),
                disabled: true,
              ),
              m.NavigationRailDestination(
                icon: m.Icon(m.Icons.event),
                label: Text('Calendar'),
              ),
            ],
          ),
        ),
        scale: 2,
      ),
    );
    expect(find.byType(m.NavigationRail), findsNothing);
    destinationFocus(tester, 'Overview').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow navigation and long list content grow with text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: 170,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaNavigationBar(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    destinations: const [
                      m.NavigationDestination(
                        icon: m.Icon(m.Icons.home),
                        label: 'Home overview',
                      ),
                      m.NavigationDestination(
                        icon: m.Icon(m.Icons.event),
                        label: 'Calendar events',
                      ),
                    ],
                  ),
                  const LuminaListTile(
                    title: Text('A long multiline title'),
                    subtitle: Text('Supporting information'),
                    leading: m.Icon(m.Icons.person),
                    trailing: m.Icon(m.Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ),
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(m.ListTile), findsNothing);
    expect(
      tester.getSize(find.byType(LuminaListTile)).height,
      greaterThan(100),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'tabs share selection across taps, controller index and page swipes',
    (tester) async {
      final semantics = tester.ensureSemantics();

      final controller = m.TabController(length: 3, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          Column(
            children: [
              LuminaTabs(
                controller: controller,
                tabs: const [
                  m.Tab(text: 'First'),
                  m.Tab(text: 'Second'),
                  m.Tab(text: 'Third'),
                ],
              ),
              Expanded(
                child: m.TabBarView(
                  controller: controller,
                  children: const [
                    Text('First page'),
                    Text('Second page'),
                    Text('Third page'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.byType(m.TabBar), findsNothing);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(controller.index, 1);
      controller.index = 2;
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.text('Third'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await tester.drag(find.byType(m.TabBarView), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(controller.index, 1);
      expect(
        tester
            .getSemantics(find.text('Second'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'tabs resolve default controller and avoid Material Tab fixed heights',
    (tester) async {
      await tester.pumpWidget(
        host(
          m.DefaultTabController(
            length: 2,
            initialIndex: 1,
            child: SizedBox(
              width: 180,
              child: LuminaTabs(
                tabs: const [
                  m.Tab(icon: m.Icon(m.Icons.home), text: 'Overview'),
                  m.Tab(text: 'Calendar'),
                ],
              ),
            ),
          ),
          scale: 3,
        ),
      );
      await tester.pump();
      expect(find.byType(m.Tab), findsNothing);
      final tabsBounds = tester.getRect(find.byType(LuminaTabs));
      final selectedBounds = tester.getRect(find.text('Calendar'));
      expect(selectedBounds.left, greaterThanOrEqualTo(tabsBounds.left));
      expect(selectedBounds.right, lessThanOrEqualTo(tabsBounds.right));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(LuminaTabs)).height, greaterThan(100));
    },
  );

  testWidgets(
    'overflow selection reveals only its own viewport inside a page',
    (tester) async {
      final outer = ScrollController();
      final tabs = m.TabController(length: 3, initialIndex: 2, vsync: tester);
      addTearDown(outer.dispose);
      addTearDown(tabs.dispose);
      await tester.pumpWidget(
        host(
          SingleChildScrollView(
            controller: outer,
            child: Column(
              children: [
                const Text('Page top'),
                const SizedBox(height: 900),
                SizedBox(
                  width: 180,
                  child: LuminaTabs(
                    controller: tabs,
                    tabs: const [
                      m.Tab(text: 'First'),
                      m.Tab(text: 'Second'),
                      m.Tab(text: 'Third'),
                    ],
                  ),
                ),
                const SizedBox(height: 150),
                LuminaNavigationRail(
                  selectedIndex: 1,
                  onDestinationSelected: (_) {},
                  destinations: const [
                    m.NavigationRailDestination(
                      icon: m.Icon(m.Icons.home),
                      label: Text('Rail first'),
                    ),
                    m.NavigationRailDestination(
                      icon: m.Icon(m.Icons.event),
                      label: Text('Rail second'),
                    ),
                  ],
                ),
                const SizedBox(height: 150),
                SizedBox(
                  width: 600,
                  child: LuminaNavigationBar(
                    selectedIndex: 1,
                    onDestinationSelected: (_) {},
                    destinations: const [
                      m.NavigationDestination(
                        icon: m.Icon(m.Icons.home),
                        label: 'Bar first',
                      ),
                      m.NavigationDestination(
                        icon: m.Icon(m.Icons.event),
                        label: 'Bar second',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(outer.offset, 0);
      final inner = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(LuminaTabs),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(inner.controller!.offset, greaterThan(0));
      tabs.index = 0;
      await tester.pump();
      await tester.pump();
      expect(outer.offset, 0);
      expect(inner.controller!.offset, 0);
      tabs.index = 2;
      await tester.pump();
      await tester.pump();
      expect(outer.offset, 0);
      expect(inner.controller!.offset, greaterThan(0));
      final viewport = tester.getRect(find.byType(LuminaTabs));
      final selection = tester.getRect(find.text('Third'));
      expect(selection.left, greaterThanOrEqualTo(viewport.left));
      expect(selection.right, lessThanOrEqualTo(viewport.right));
      destinationFocus(tester, 'Third').requestFocus();
      await tester.pump();
      expect(outer.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
