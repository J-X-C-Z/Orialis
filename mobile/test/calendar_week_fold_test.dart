import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_layout.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_view.dart';

CalendarEvent _event(
  String id,
  DateTime start,
  DateTime end, {
  bool allDay = false,
}) => CalendarEvent(
  id: id,
  title: id,
  startAt: start.toIso8601String(),
  endAt: end.toIso8601String(),
  allDay: allDay,
  important: false,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

void main() {
  final monday = DateTime(2026, 11, 2);
  test(
    'folded axis keeps occupied hours and round trips all minute coordinates',
    () {
      final events = [
        _event(
          'cross-midnight',
          DateTime(2026, 11, 2, 23, 30),
          DateTime(2026, 11, 3, 0, 30),
        ),
        _event('first', DateTime(2026, 11, 2, 8), DateTime(2026, 11, 2, 10)),
        _event('overlap', DateTime(2026, 11, 2, 9), DateTime(2026, 11, 2, 11)),
      ];
      final days = [
        for (var day = 2; day <= 8; day++)
          layoutCalendarDay(DateTime(2026, 11, day), events),
      ];
      final axis = CalendarWeekAxis(days.expand((day) => day), collapsed: true);
      expect(axis.extent, lessThan(24 * 72));
      expect(axis.offsetForMinute(60) - axis.offsetForMinute(0), 72);
      expect(axis.offsetForMinute(1440) - axis.offsetForMinute(1380), 72);
      expect(axis.offsetForMinute(660) - axis.offsetForMinute(480), 3 * 72);
      expect(
        days.first
            .where((entry) => entry.event.id != 'cross-midnight')
            .map((entry) => entry.columns),
        [2, 2],
      );
      for (var minute = 0.0; minute <= 1440; minute++) {
        expect(
          axis.minuteForOffset(axis.offsetForMinute(minute)),
          closeTo(minute, 1e-8),
        );
      }
      for (final entry in days.expand((day) => day)) {
        expect(
          axis.offsetForMinute(entry.endMinute) -
              axis.offsetForMinute(entry.startMinute),
          closeTo((entry.endMinute - entry.startMinute) * 1.2, 1e-8),
        );
      }
    },
  );

  test('exclusive event end permits folding the next hour; all-day does not occupy time', () {
    final entries = layoutCalendarDay(monday, [
      _event('hour', DateTime(2026, 11, 2, 8), DateTime(2026, 11, 2, 9)),
      _event('all-day', monday, DateTime(2026, 11, 3), allDay: true),
    ]);
    final axis = CalendarWeekAxis(entries, collapsed: true);
    expect(
      axis.segments
          .where((s) => s.collapsed)
          .map((s) => (s.startMinute, s.endMinute)),
      [(0.0, 480.0), (540.0, 1440.0)],
    );
    expect(CalendarWeekAxis(entries).extent, 24 * 72);
  });

  test('empty folded week remains a reversible full-day gap', () {
    final axis = CalendarWeekAxis(const [], collapsed: true);
    expect(axis.segments.length, 1);
    expect(axis.extent, 28);
    expect(axis.minuteForOffset(14), 720);
    expect(axis.offsetForMinute(720), 14);
    expect(axis.minuteForOffset(-10), 0);
    expect(axis.minuteForOffset(100), 1440);
    expect(CalendarWeekAxis(const []).extent, 1728);
  });

  for (final empty in [false, true]) {
    testWidgets(
      'parent-controlled fold preserves real click times (empty=$empty)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final events = empty
            ? <CalendarEvent>[]
            : [
                _event(
                  'timed',
                  DateTime(2026, 11, 2, 8),
                  DateTime(2026, 11, 2, 9),
                ),
                _event('all-day', monday, DateTime(2026, 11, 3), allDay: true),
              ];
        DateTime? created;
        var collapsed = false;
        late StateSetter rebuild;
        await tester.pumpWidget(
          WidgetsApp(
            color: const Color(0xff000000),
            builder: (context, _) => LuminaTheme(
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return CalendarWeekView(
                    collapseFreeHours: collapsed,
                    date: monday,
                    eventsOn: (day) => day.day == 2 ? events : const [],
                    tasksOn: (_) => const [],
                    onSelect: (_) {},
                    onEvent: (_) {},
                    onCreate: (date) => created = date,
                    onAgenda: (_) {},
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('calendar-week-fold-hours')),
          findsNothing,
        );
        rebuild(() => collapsed = true);
        await tester.pumpAndSettle();
        if (empty) {
          expect(find.text('本周暂无定时日程 · 00:00–24:00'), findsOneWidget);
        } else {
          expect(
            find.byKey(
              const ValueKey('calendar-week-allday-2026-11-02-all-day'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('calendar-week-event-2026-11-02-timed')),
            findsOneWidget,
          );
        }
        final axis = CalendarWeekAxis(
          layoutCalendarDay(monday, events),
          collapsed: true,
        );
        final dayColumn = find.byKey(
          const ValueKey('calendar-week-day-2026-11-03'),
        );
        await tester.tapAt(
          tester.getTopLeft(dayColumn) + Offset(10, axis.offsetForMinute(570)),
        );
        await tester.pumpAndSettle();
        expect(created, DateTime(2026, 11, 3, 9, 30));
        rebuild(() => collapsed = false);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('calendar-week-time-8')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'initial folded week and a shorter next week keep valid offsets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var date = monday;
      late StateSetter rebuild;
      final event = _event(
        'long',
        DateTime(2026, 11, 2, 7),
        DateTime(2026, 11, 2, 20),
      );
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xff000000),
          builder: (context, _) => LuminaTheme(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return CalendarWeekView(
                  date: date,
                  collapseFreeHours: true,
                  eventsOn: (day) => day.day == 2 ? [event] : const [],
                  tasksOn: (_) => const [],
                  onSelect: (_) {},
                  onEvent: (_) {},
                  onCreate: (_) {},
                  onAgenda: (_) {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('calendar-week-hours')),
          )
          .controller!;
      expect(controller.offset, 0);
      controller.jumpTo(300);
      rebuild(() => date = DateTime(2026, 11, 9));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.text('本周暂无定时日程 · 00:00–24:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'week hours pass behind floating headers and all-day symbols open details',
    (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final single = _event(
        '很长的全天日程标题',
        monday,
        DateTime(2026, 11, 3),
        allDay: true,
      );
      final multiple = [
        _event(
          '多项全天甲',
          DateTime(2026, 11, 3),
          DateTime(2026, 11, 4),
          allDay: true,
        ),
        _event(
          '多项全天乙',
          DateTime(2026, 11, 3),
          DateTime(2026, 11, 4),
          allDay: true,
        ),
      ];
      CalendarEvent? opened;
      DateTime? agenda;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xff000000),
          builder: (context, _) => LuminaTheme(
            child: CalendarWeekView(
              date: monday,
              topInset: 80,
              bottomInset: 96,
              eventsOn: (day) => day.day == 2
                  ? [single]
                  : day.day == 3
                  ? multiple
                  : const [],
              tasksOn: (day) => day.day == 2
                  ? const [
                      Task(
                        id: 'due',
                        title: '截止任务',
                        completed: false,
                        version: 1,
                        remoteVersion: 0,
                        localRevision: 0,
                        createdAt: '',
                        updatedAt: '',
                        syncStatus: 'synced',
                      ),
                    ]
                  : const [],
              onSelect: (_) {},
              onEvent: (event) => opened = event,
              onCreate: (_) {},
              onAgenda: (date) => agenda = date,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = find.byKey(
        const ValueKey('calendar-week-floating-header'),
      );
      final hours = find.byKey(const PageStorageKey('calendar-week-hours'));
      final timeline = find.byKey(const ValueKey('calendar-week-timeline'));
      final headerPosition = tester.getTopLeft(header);
      final information = find.byKey(
        const ValueKey('calendar-week-information-flow'),
      );
      final informationPosition = tester.getTopLeft(information);
      expect(tester.widget<SingleChildScrollView>(hours).controller!.offset, 0);
      expect(
        informationPosition.dy,
        greaterThan(tester.getRect(header).bottom),
      );
      expect(
        find.descendant(
          of: header,
          matching: find.byKey(const ValueKey('calendar-week-due-2026-11-02')),
        ),
        findsNothing,
      );
      expect(headerPosition.dy, 80);
      expect(tester.getRect(hours), tester.getRect(timeline));
      for (final title in [
        single.title,
        ...multiple.map((event) => event.title),
      ]) {
        expect(find.text(title), findsNothing);
      }
      final singleSymbol = find.byKey(
        ValueKey('calendar-week-allday-2026-11-02-${single.id}'),
      );
      expect(tester.getSize(singleSymbol).height, greaterThanOrEqualTo(44));
      await tester.tap(singleSymbol);
      expect(opened, same(single));
      await tester.tap(
        find.byKey(const ValueKey('calendar-week-allday-2026-11-03')),
      );
      expect(agenda, DateTime(2026, 11, 3));
      expect(
        find.byKey(const ValueKey('calendar-week-due-2026-11-02')),
        findsOneWidget,
      );
      final surfaces = find.descendant(
        of: header,
        matching: find.byType(LuminaSurface),
      );
      for (final surface in surfaces.evaluate()) {
        expect(
          tester.getSize(find.byWidget(surface.widget)).width,
          lessThan(tester.getSize(header).width),
        );
      }
      await tester.drag(hours, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header), headerPosition);
      expect(
        tester.getTopLeft(information).dy,
        lessThan(informationPosition.dy),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('calendar-week-time-0'))).top,
        lessThan(tester.getRect(header).bottom),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
