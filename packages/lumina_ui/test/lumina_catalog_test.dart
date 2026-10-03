import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  testWidgets('page title stays centered in a card while content scrolls', (
    tester,
  ) async {
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.MediaQuery(
          data: const m.MediaQueryData(
            size: m.Size(400, 800),
            textScaler: m.TextScaler.linear(2),
          ),
          child: LuminaTheme(
            child: LuminaPageScaffold(
              title: '我的',
              actions: [
                LuminaIconButton(
                  onPressed: () {},
                  icon: const m.Icon(m.Icons.settings),
                  tooltip: '设置',
                ),
              ],
              body: m.Builder(
                builder: (context) => m.ListView.builder(
                  padding: m.EdgeInsets.only(
                    top: LuminaPageHeaderInset.of(context),
                  ),
                  itemCount: 24,
                  itemBuilder: (context, index) => m.SizedBox(
                    key: m.ValueKey('row-$index'),
                    height: 80,
                    child: m.Text('内容 $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final title = find.text('我的');
    final before = tester.getCenter(title);
    final width = tester.getSize(find.byType(LuminaTopBar)).width;
    expect((before.dx - width / 2).abs(), lessThan(1));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(LuminaCardScope), findsOneWidget);
    await tester.drag(find.byType(m.ListView), const m.Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getCenter(title), before);
    expect(
      tester.getTopLeft(find.byKey(const m.ValueKey('row-0'))).dy,
      lessThan(tester.getBottomLeft(find.byType(LuminaTopBar)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme mode selector changes between system, light and dark', (
    tester,
  ) async {
    var selected = m.ThemeMode.system;
    await tester.pumpWidget(
      m.MaterialApp(
        home: LuminaTheme(
          child: m.Scaffold(
            body: m.StatefulBuilder(
              builder: (context, setState) => LuminaThemeModeSelector(
                value: selected,
                onChanged: (next) => setState(() => selected = next),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(selected, m.ThemeMode.dark);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(selected, m.ThemeMode.light);
  });

  testWidgets('native navigation and multiple selection retain interaction', (
    tester,
  ) async {
    var destination = 0;
    var selected = <int>{1};
    await tester.pumpWidget(
      m.MaterialApp(
        home: LuminaTheme(
          brightness: Brightness.dark,
          child: m.StatefulBuilder(
            builder: (context, setState) => m.Scaffold(
              body: m.Center(
                child: LuminaMultiSegmented<int>(
                  segments: const [
                    m.ButtonSegment(value: 1, label: Text('One')),
                    m.ButtonSegment(value: 2, label: Text('Two')),
                  ],
                  selected: selected,
                  onSelectionChanged: (next) => setState(() => selected = next),
                ),
              ),
              bottomNavigationBar: LuminaNavigationBar(
                selectedIndex: destination,
                onDestinationSelected: (next) =>
                    setState(() => destination = next),
                destinations: const [
                  m.NavigationDestination(
                    icon: m.Icon(m.Icons.home),
                    label: 'Home',
                  ),
                  m.NavigationDestination(
                    icon: m.Icon(m.Icons.event),
                    label: 'Events',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(selected, {1, 2});
    await tester.tap(find.text('Events'));
    await tester.pumpAndSettle();
    expect(destination, 1);
    expect(find.byType(m.NavigationBar), findsNothing);
    final surfaces = tester.widgetList<LuminaSurface>(
      find.descendant(
        of: find.byType(LuminaNavigationBar),
        matching: find.byType(LuminaSurface),
      ),
    );
    expect(surfaces.any((surface) => surface.glass), isTrue);
    final colors = LuminaTheme.of(tester.element(find.text('Events'))).colors;
    expect(colors.dark, isTrue);
    final text = colors.ink.computeLuminance(),
        surface = colors.surface.computeLuminance();
    expect((text + .05) / (surface + .05), greaterThan(7));
  });

  testWidgets('radio group and continuous slider preserve interaction', (
    tester,
  ) async {
    var choice = 1;
    var value = .25;
    await tester.pumpWidget(
      m.MaterialApp(
        home: LuminaTheme(
          child: m.StatefulBuilder(
            builder: (context, setState) => m.Scaffold(
              body: m.Column(
                children: [
                  LuminaRadio<int>(
                    value: 2,
                    groupValue: choice,
                    onChanged: (next) => setState(() => choice = next!),
                  ),
                  LuminaContinuousSlider(
                    value: value,
                    onChanged: (next) => setState(() => value = next),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(m.Radio<int>));
    await tester.pumpAndSettle();
    expect(choice, 2);
    await tester.drag(find.byType(m.Slider), const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(value, greaterThan(.25));
  });
}
