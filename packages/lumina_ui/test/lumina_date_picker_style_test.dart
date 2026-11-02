import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _picker({
  double scale = 1,
  double motionScale = 1,
  required ValueChanged<DateTime?> onResult,
}) => m.MaterialApp(
  home: m.Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: LuminaTheme(
        data: LuminaThemeData(motionScale: motionScale),
        child: m.Builder(
          builder: (context) => Center(
            child: LuminaButton(
              child: const Text('选择日期'),
              onPressed: () async => onResult(
                await showLuminaDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 10, 15),
                  firstDate: DateTime(2026),
                  lastDate: DateTime(2027),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Finder _day(String day) => find.byKey(ValueKey('date-picker-day-$day'));

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('date picker matches calendar styling at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_picker(scale: scale, onResult: (_) {}));
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      expect(find.text('2026/10'), findsOneWidget);
      final selected = tester.widget<LuminaSurface>(_day('2026-10-15'));
      final theme = LuminaTheme.of(tester.element(_day('2026-10-15')));
      expect(selected.glass, isTrue);
      expect(selected.diffuseGlass, isTrue);
      expect(selected.color, theme.colors.accentSoft);
      final selectedText = tester.widget<Text>(
        find.descendant(of: _day('2026-10-15'), matching: find.text('15')),
      );
      expect(selectedText.style!.color, theme.colors.accent);
      expect(selectedText.style!.fontWeight, FontWeight.w700);
      final weekend = tester.widget<LuminaSurface>(_day('2026-10-17'));
      expect(weekend.glass, isTrue);
      expect(weekend.diffuseGlass, isTrue);
      expect(
        weekend.color,
        Color.lerp(theme.colors.surface, theme.colors.accent, .07),
      );
      expect(
        tester.getSize(_day('2026-10-15')).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'month navigation confirms the selected day and cancel returns null',
    (tester) async {
      final results = <DateTime?>[];
      await tester.pumpWidget(_picker(onResult: results.add));
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is LuminaIconButton && widget.tooltip == '下个月',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026/11'), findsOneWidget);
      await tester.tap(_day('2026-11-20'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(results, [DateTime(2026, 11, 20)]);
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [DateTime(2026, 11, 20), null]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('caller motion scale zero disables dialog entrance and exit', (
    tester,
  ) async {
    final results = <DateTime?>[];
    await tester.pumpWidget(_picker(motionScale: 0, onResult: results.add));
    await tester.tap(find.text('选择日期'));
    await tester.pump();
    final route = ModalRoute.of(tester.element(_day('2026-10-15')))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(route.animation!.value, 1);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(results, [null]);
    expect(find.byType(LuminaDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
