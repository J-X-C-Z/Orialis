import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  Future<void> host(WidgetTester tester, {bool accessible = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              accessibleNavigation: accessible,
            ),
            child: LuminaTheme(
              data: const LuminaThemeData(motionScale: 0),
              child: LuminaPageScaffold(
                title: '列表',
                floatingActionButton: LuminaFloatingActionButton(
                  icon: const LuminaIcon(LuminaIcons.add),
                  onPressed: () {},
                ),
                body: ListView(
                  children: [
                    for (var i = 0; i < 60; i++)
                      SizedBox(height: 60, child: Text('行 $i')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  double fabOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(LuminaFloatingActionButton),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      )
      .opacity;

  testWidgets('floating button steps aside while scrolling down', (
    tester,
  ) async {
    await host(tester);
    expect(fabOpacity(tester), 1);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(fabOpacity(tester), 0);
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(fabOpacity(tester), 1);
  });

  testWidgets('floating button stays for accessible navigation', (
    tester,
  ) async {
    await host(tester, accessible: true);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(fabOpacity(tester), 1);
  });
}
