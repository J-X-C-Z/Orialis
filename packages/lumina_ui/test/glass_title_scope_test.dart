import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'scoped section/card/calendar titles share glass material dark=$dark',
      (tester) async {
        Future<void> show(
          bool enabled, {
          bool contrast = false,
          bool opaque = false,
        }) async {
          await tester.pumpWidget(
            WidgetsApp(
              color: const Color(0xffe0e0e0),
              builder: (context, _) => MediaQuery(
                data: MediaQueryData(
                  textScaler: const TextScaler.linear(2),
                  highContrast: contrast,
                ),
                child: LuminaTheme(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  reduceTransparency: opaque,
                  data: const LuminaThemeData(
                    neumorphic: true,
                    neumorphicGlass: true,
                  ),
                  child: LuminaGlassTitleScope(
                    enabled: enabled,
                    child: DefaultTextStyle(
                      style: const TextStyle(fontSize: 15),
                      child: Center(
                        child: SizedBox(
                          width: 340,
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                const LuminaSection(
                                  title: '设置分区',
                                  child: Text('设置内容'),
                                ),
                                const LuminaSection(
                                  title: '四象限',
                                  raised: true,
                                  child: Text('任务内容'),
                                ),
                                const LuminaTitledContentCard(
                                  title: '当天截止',
                                  emptyText: '没有截止',
                                  children: [],
                                ),
                                const LuminaCardHeader(
                                  title: '手动保持原样',
                                  glassTitle: false,
                                ),
                              ],
                            ),
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
        }

        await show(true);
        final titles = find.byKey(const ValueKey('lumina-glass-card-title'));
        expect(titles, findsNWidgets(3));
        for (final title in ['设置分区', '四象限', '当天截止']) {
          final heading = find.ancestor(of: find.text(title), matching: titles);
          expect(heading, findsOneWidget);
          expect(
            find.descendant(
              of: heading,
              matching: find.byType(LuminaGlassWell),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: heading,
              matching: find.byType(LuminaGlassCoat),
            ),
            findsOneWidget,
          );
        }
        expect(
          find.ancestor(of: find.text('手动保持原样'), matching: titles),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await show(false);
        expect(titles, findsNothing);
        await show(true, contrast: true);
        expect(titles, findsNothing);
        await show(true, opaque: true);
        expect(titles, findsNWidgets(3));
        expect(
          find
              .byType(BackdropFilter)
              .evaluate()
              .every((element) => !(element.widget as BackdropFilter).enabled),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
