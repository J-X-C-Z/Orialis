import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _harness(Widget child, Brightness brightness, bool liquidGlass) =>
    WidgetsApp(
      color: const Color(0xff000000),
      builder: (context, _) => MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          disableAnimations: true,
        ),
        child: LuminaTheme(
          brightness: brightness,
          data: LuminaThemeData(liquidGlass: liquidGlass),
          child: DefaultTextStyle(
            style: LuminaTextTheme(
              LuminaColors(dark: brightness == Brightness.dark),
            ).bodyMedium,
            child: Navigator(
              onGenerateRoute: (_) =>
                  PageRouteBuilder<void>(pageBuilder: (context, a, b) => child),
            ),
          ),
        ),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    for (final liquidGlass in [false, true]) {
      testWidgets(
        'attachment sheet rows are cards in $brightness liquid=$liquidGlass',
        (tester) async {
          String? selected;
          await tester.pumpWidget(
            _harness(
              Builder(
                builder: (context) => GestureDetector(
                  onTap: () async {
                    selected = await showLuminaSheet<String>(
                      context: context,
                      builder: (context) => LuminaStack(
                        children: [
                          LuminaListRow(
                            title: '选择照片',
                            onTap: () => Navigator.of(context).pop('photos'),
                          ),
                          LuminaListRow(
                            title: '选择文件',
                            onTap: () => Navigator.of(context).pop('files'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('附件'),
                ),
              ),
              brightness,
              liquidGlass,
            ),
          );
          await tester.tap(find.text('附件'));
          await tester.pumpAndSettle();
          final materials = tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .map((widget) => widget.painter)
              .where((p) => p.runtimeType.toString() == '_LuminaMaterial')
              .cast<dynamic>()
              .toList();
          expect(materials.length, 3);
          for (final material in materials) {
            expect(material.glass, isFalse);
            expect(material.liquidGlass, isFalse);
            expect(material.tint.a, 1);
          }
          expect(find.byType(BackdropFilter), findsNothing);
          await tester.tap(find.text('选择文件'));
          await tester.pumpAndSettle();
          expect(selected, 'files');
          expect(find.text('选择照片'), findsNothing);
        },
      );
      testWidgets('${brightness.name} liquid=$liquidGlass menu keeps a card', (
        tester,
      ) async {
        await tester.pumpWidget(
          _harness(
            LuminaMenuAnchor(
              menuChildren: [
                LuminaMenuItem(
                  onPressed: () {},
                  child: const Text('Menu item'),
                ),
              ],
              builder: (context, controller, child) => LuminaButton(
                onPressed: controller.open,
                child: const Text('Open menu'),
              ),
            ),
            brightness,
            liquidGlass,
          ),
        );
        await tester.tap(find.text('Open menu'));
        await tester.pumpAndSettle();
        final container = find.byWidgetPredicate(
          (widget) => widget is LuminaSurface && widget.radius == 22,
        );
        final dynamic card = tester
            .widget<CustomPaint>(
              find
                  .descendant(of: container, matching: find.byType(CustomPaint))
                  .first,
            )
            .painter;
        expect(card.glass, isFalse);
        expect(card.liquidGlass, isFalse);
        expect(card.tint.a, 1);
        expect(card.colors.dark, brightness == Brightness.dark);
        expect(
          LuminaTheme.of(tester.element(find.text('Menu item')))
              .data
              .liquidGlass,
          liquidGlass,
        );
        Focus.of(tester.element(find.text('Menu item'))).requestFocus();
        await tester.pumpAndSettle();
        final item = find.byType(m.MenuItemButton);
        final paints = tester
            .widgetList<CustomPaint>(
              find.descendant(of: item, matching: find.byType(CustomPaint)),
            )
            .map((widget) => widget.painter)
            .where((p) => p.runtimeType.toString() == '_LuminaMaterial')
            .cast<dynamic>();
        expect(paints, isNotEmpty);
        expect(paints.every((p) => p.liquidGlass == liquidGlass), isTrue);
        await tester.tap(find.text('Menu item'));
        await tester.pumpAndSettle();
        expect(find.text('Menu item'), findsNothing);
        expect(tester.takeException(), isNull);
      });
      for (final sheet in [false, true]) {
        testWidgets(
          '${brightness.name} liquid=$liquidGlass ${sheet ? 'sheet' : 'dialog'} keeps a solid card and child material',
          (tester) async {
            String? result;
            await tester.pumpWidget(
              _harness(
                Builder(
                  builder: (context) => Center(
                    child: GestureDetector(
                      onTap: () async {
                        Widget action(BuildContext context) => LuminaButton(
                          onPressed: () => Navigator.of(context).pop('done'),
                          child: const Text('Confirm'),
                        );
                        result = sheet
                            ? await showLuminaSheet<String>(
                                context: context,
                                builder: action,
                              )
                            : await showLuminaDialog<String>(
                                context: context,
                                builder: (context) => LuminaDialog(
                                  title: 'Card dialog',
                                  content: const Text('Content'),
                                  actions: [action(context)],
                                ),
                              );
                      },
                      child: const Text('Open'),
                    ),
                  ),
                ),
                brightness,
                liquidGlass,
              ),
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            final materials = tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .where(
                  (painter) =>
                      painter.runtimeType.toString() == '_LuminaMaterial',
                )
                .cast<dynamic>()
                .toList();
            final card = materials.first;
            expect(card.glass, isFalse);
            expect(card.liquidGlass, isFalse);
            expect(card.tint.a, 1);
            expect(card.depth, LuminaSurfaceDepth.raised);
            expect(card.colors.dark, brightness == Brightness.dark);
            expect(find.byType(BackdropFilter), findsNothing);
            expect(
              materials
                  .skip(1)
                  .every((p) => p.liquidGlass == (sheet ? false : liquidGlass)),
              isTrue,
            );
            expect(
              LuminaTheme.of(tester.element(find.text('Confirm')))
                  .data
                  .liquidGlass,
              liquidGlass,
            );
            await tester.tap(find.text('Confirm'));
            await tester.pumpAndSettle();
            expect(result, 'done');
            expect(find.text('Confirm'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
