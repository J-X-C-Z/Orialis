import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  for (final hybrid in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'hybrid=$hybrid ${brightness.name}: soft controls keep input and selection usable',
        (tester) async {
          final input = TextEditingController();
          addTearDown(input.dispose);
          var selected = 0;
          var taps = 0;
          await tester.pumpWidget(
            WidgetsApp(
              color: const Color(0xFFE0E0E0),
              builder: (context, _) => LuminaTheme(
                brightness: brightness,
                data: LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: hybrid,
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(fontSize: 15),
                  child: Center(
                    child: SizedBox(
                      width: 320,
                      child: StatefulBuilder(
                        builder: (context, update) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LuminaTextField(controller: input, label: 'Task'),
                            LuminaButton(
                              onPressed: () => taps++,
                              child: const Text('Save'),
                            ),
                            LuminaSegmented<int>(
                              items: const {0: 'Today', 1: 'Week'},
                              value: selected,
                              onChanged: (value) =>
                                  update(() => selected = value),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (hybrid) {
            expect(find.byType(LuminaGlassCoat), findsWidgets);
          } else {
            expect(find.byType(BackdropFilter), findsNothing);
          }
          expect(find.byType(RawMagnifier), findsNothing);
          await tester.enterText(find.byType(EditableText), 'Keep this draft');
          await tester.tap(find.text('Week'));
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(input.text, 'Keep this draft');
          final press = await tester.startGesture(
            tester.getCenter(find.text('Save')),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(taps, 0);
          await press.up();
          await tester.pumpAndSettle();
          expect(taps, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
