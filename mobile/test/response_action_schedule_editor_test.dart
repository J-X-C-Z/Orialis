import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/response_schedule_editor.dart';

const _schedule = <String, dynamic>{
  'id': 'study',
  'label': '学习安排',
  'title': '复习',
  'kind': 'schedule',
  'startAt': '2026-10-26T09:00:00+08:00',
  'endAt': '2026-10-26T10:00:00+08:00',
};
Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  builder: (context, child) => LuminaTheme(
    highPerformanceMode: true,
    child: MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is LuminaTextField && w.label == label),
  matching: find.byType(EditableText),
);
void main() {
  testWidgets(
    '320 large text editor scrolls above keyboard and rejects reverse range',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => LuminaButton(
              onPressed: () => showLuminaDialog<Map<String, dynamic>>(
                context: context,
                builder: (_) => ResponseScheduleEditor(
                  item: {..._schedule, 'endAt': _schedule['startAt']},
                ),
              ),
              child: const Text('打开'),
            ),
          ),
          scale: 2,
        ),
      );
      await _tap(tester, find.text('打开'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_field('备注'));
      await tester.enterText(_field('备注'), '键盘输入');
      await _tap(tester, find.text('确认添加'));
      expect(find.text('结束时间必须晚于开始时间'), findsOneWidget);
      expect(find.byType(ResponseScheduleEditor), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('schedule-start-time')));
      expect(tester.takeException(), isNull);
      final strings = LuminaLocalizations.of(
        tester.element(find.byType(LuminaDialog).last),
      );
      await _tap(tester, find.text(strings.cancel).last);
      await _tap(tester, find.byKey(const ValueKey('schedule-start-date')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'cancel returns no edits and confirmation preserves the original instant',
    (tester) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => LuminaButton(
              onPressed: () async {
                result = await showLuminaDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) => const ResponseScheduleEditor(item: _schedule),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('打开'));
      await tester.enterText(_field('标题'), '取消修改');
      await _tap(tester, find.text('取消'));
      expect(result, isNull);
      await _tap(tester, find.text('打开'));
      expect(tester.widget<EditableText>(_field('标题')).controller.text, '复习');
      await tester.enterText(_field('标题'), '修改后的标题');
      await _tap(tester, find.text('确认添加'));
      expect(result!['title'], '修改后的标题');
      expect(result!['startAt'], '2026-10-26T01:00:00.000Z');
      expect(result!['endAt'], '2026-10-26T02:00:00.000Z');
      expect(result!['location'], isNull);
      expect(result!['notes'], isNull);
      expect(
        result!.keys,
        unorderedEquals(['title', 'startAt', 'endAt', 'location', 'notes']),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
