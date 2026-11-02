import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_view.dart';

CalendarEvent _event(String id, String title, int minutes) => CalendarEvent(
  id: id,
  title: title,
  location: '教学楼',
  description: '带讲义',
  startAt: DateTime(2026, 11, 2, 8).toIso8601String(),
  endAt: DateTime(2026, 11, 2, 8, minutes).toIso8601String(),
  allDay: false,
  important: false,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

Future<void> _show(
  WidgetTester tester,
  CalendarEvent event, {
  double width = 360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    WidgetsApp(
      color: const Color(0xffe1e4e8),
      builder: (context, _) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: LuminaTheme(
          data: const LuminaThemeData(neumorphic: true),
          child: CalendarWeekView(
            date: DateTime(2026, 11, 2),
            eventsOn: (date) => date.day == 2 ? [event] : [],
            tasksOn: (_) => const [],
            onSelect: (_) {},
            onEvent: (_) {},
            onCreate: (_) {},
            onAgenda: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [360.0, 900.0]) {
    testWidgets(
      'raised week cards use spare space for muted details at $width',
      (tester) async {
        await _show(tester, _event('long', '课程', 180), width: width);
        final card = find.byKey(
          const ValueKey('calendar-week-event-2026-11-02-long'),
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is LuminaSurface &&
                  widget.depth == LuminaSurfaceDepth.raised,
            ),
          ),
          findsOneWidget,
        );
        final details = find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (widget) => widget is Text && widget.data!.contains('教学楼'),
          ),
        );
        expect(details, findsOneWidget);
        final text = tester.widget<Text>(details);
        expect(text.data, '08:00–11:00\n教学楼\n带讲义');
        expect(
          text.style!.color,
          LuminaTheme.of(tester.element(details)).colors.muted,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('short cards reserve space for the title at large text sizes', (
    tester,
  ) async {
    await _show(tester, _event('short', '较长的课程标题', 40), textScale: 2);
    final card = find.byKey(
      const ValueKey('calendar-week-event-2026-11-02-short'),
    );
    expect(
      find.descendant(of: card, matching: find.text('较长的课程标题')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) => widget is Text && widget.data!.contains('教学楼'),
        ),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
