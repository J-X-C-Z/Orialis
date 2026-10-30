import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show DesktopLayoutScope;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/pages/calendar/calendar_page.dart';

class _CalendarConfig extends AppConfig {
  @override
  Future<String> deviceId() async => 'calendar-views-test';
}

Widget _calendar(
  AppDatabase database, {
  bool desktop = false,
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(_CalendarConfig()),
    desktopModeProvider.overrideWithValue(desktop),
  ],
  child: WidgetsApp(
    color: const Color(0xff000000),
    builder: (context, _) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: LuminaTheme(
        child: DefaultTextStyle(
          style: const LuminaTextTheme(LuminaColors(dark: false)).bodyMedium,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, a, b) {
                final page = CalendarPage(initialDate: DateTime(2026, 10, 15));
                return desktop ? DesktopLayoutScope(child: page) : page;
              },
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<AppDatabase> _database() async {
  final database = AppDatabase(executor: NativeDatabase.memory());
  final events = EventRepository(database: database, config: _CalendarConfig());
  await events.createCalendarEvent(
    eventId: 'morning',
    title: '电路理论基础',
    location: '南校教学楼',
    startAt: DateTime(2026, 10, 15, 9),
    endAt: DateTime(2026, 10, 15, 10),
  );
  await events.createCalendarEvent(
    eventId: 'overlap',
    title: '实验讨论',
    startAt: DateTime(2026, 10, 15, 9, 30),
    endAt: DateTime(2026, 10, 15, 11),
  );
  await events.createCalendarEvent(
    eventId: 'all-day',
    title: '全天研讨会',
    startAt: DateTime(2026, 10, 15),
    endAt: DateTime(2026, 10, 16),
    allDay: true,
  );
  await events.createTask(title: '提交实验报告', due: '2026-10-15');
  await events.createCalendarEvent(
    eventId: 'next-day',
    title: '周五课程',
    startAt: DateTime(2026, 10, 16, 14),
    endAt: DateTime(2026, 10, 16, 15),
  );
  return database;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _close(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  await database.close();
}

Future<void> _select(WidgetTester tester, String view) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('calendar-view-selector')),
      matching: find.text(view),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('day week and month show distinct content and retain selection', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    final database = await _database();
    await tester.pumpWidget(_calendar(database));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-month-agenda')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-week-timeline')), findsNothing);
    expect(find.byKey(const ValueKey('calendar-day-focus')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('calendar-date-month-2026-10-16')),
    );
    await tester.pumpAndSettle();
    await _select(tester, '周');
    expect(
      find.byKey(const ValueKey('calendar-week-timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('calendar-day-focus')), findsNothing);
    expect(find.byKey(const ValueKey('calendar-month-agenda')), findsNothing);

    await _select(tester, '日');
    expect(find.byKey(const ValueKey('calendar-day-focus')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-week-timeline')), findsNothing);
    expect(
      find.byKey(const ValueKey('calendar-schedules-2026-10-16')),
      findsOneWidget,
    );
    expect(find.text('周五课程'), findsOneWidget);
    expect(find.text('电路理论基础'), findsNothing);

    await _select(tester, '月');
    expect(find.byKey(const ValueKey('calendar-month-agenda')), findsOneWidget);
    expect(find.text('10月16日 · 日程'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, database);
  });

  for (final desktop in [false, true]) {
    testWidgets(
      'week lays out seven columns and overlapping events on ${desktop ? 'desktop' : 'phone'}',
      (tester) async {
        final width = desktop ? 840.0 : 360.0;
        _size(tester, Size(width, 800));
        final database = await _database();
        await tester.pumpWidget(_calendar(database, desktop: desktop));
        await tester.pumpAndSettle();
        await _select(tester, '周');

        var previousX = -1.0;
        for (var day = 12; day <= 18; day++) {
          final date = find.byKey(ValueKey('calendar-week-date-2026-10-$day'));
          expect(date, findsOneWidget);
          final rect = tester.getRect(date);
          expect(rect.left, greaterThan(previousX));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          previousX = rect.left;
        }
        final first = tester.getRect(
          find.byKey(const ValueKey('calendar-week-event-2026-10-15-morning')),
        );
        final second = tester.getRect(
          find.byKey(const ValueKey('calendar-week-event-2026-10-15-overlap')),
        );
        expect(first.top, lessThan(second.top));
        expect(first.bottom, greaterThan(second.top));
        expect(first.overlaps(second), isFalse);
        expect(tester.takeException(), isNull);
        await _close(tester, database);
      },
    );
  }

  testWidgets('week keeps all-day details and deadline completion accessible', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    final database = await _database();
    await tester.pumpWidget(_calendar(database));
    await tester.pumpAndSettle();
    await _select(tester, '周');
    final allDay = find.byKey(
      const ValueKey('calendar-week-allday-2026-10-15-all-day'),
    );
    expect(allDay, findsOneWidget);
    expect(
      find.byKey(const ValueKey('calendar-week-allday-2026-10-16-all-day')),
      findsNothing,
    );
    await tester.tap(allDay);
    await tester.pumpAndSettle();
    expect(find.text('编辑日程'), findsOneWidget);
    Navigator.of(tester.element(find.text('编辑日程'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('calendar-week-due-2026-10-15')),
    );
    await tester.pumpAndSettle();
    final due = find.byKey(const ValueKey('calendar-due-2026-10-15'));
    expect(due, findsOneWidget);
    final complete = find.descendant(
      of: due,
      matching: find.byType(LuminaCheck),
    );
    await tester.ensureVisible(complete);
    await tester.tap(complete);
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.tasks).get()).single.completed,
      isTrue,
    );
    expect(
      find.descendant(of: due, matching: find.byType(LuminaCheck)),
      findsNothing,
    );
    expect(find.text('这一天没有截止事项。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, database);
  });

  testWidgets('calendar views fit a narrow screen with enlarged text', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    final database = await _database();
    await tester.pumpWidget(_calendar(database, textScale: 1.6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final view in ['周', '日', '月']) {
      await _select(tester, view);
    }
    await _close(tester, database);
  });

  testWidgets('tapping an empty week slot creates a schedule at that time', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    final database = await _database();
    await tester.pumpWidget(_calendar(database));
    await tester.pumpAndSettle();
    await _select(tester, '周');
    final friday = tester.getRect(
      find.byKey(const ValueKey('calendar-week-date-2026-10-16')),
    );
    final hours = tester.getRect(
      find.byKey(const PageStorageKey('calendar-week-hours')),
    );
    // The week initially opens at 08:00; one hour below it selects 09:00.
    await tester.tapAt(Offset(friday.center.dx, hours.top + 73));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(LuminaButton, '09:00'), findsOneWidget);
    expect(find.widgetWithText(LuminaButton, '10:00'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '从周视图创建');
    final save = find.widgetWithText(LuminaButton, '保存');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final created = (await database.select(database.calendarEvents).get())
        .singleWhere((event) => event.title == '从周视图创建');
    expect(
      DateTime.parse(created.startAt).toLocal(),
      DateTime(2026, 10, 16, 9),
    );
    expect(DateTime.parse(created.endAt).toLocal(), DateTime(2026, 10, 16, 10));
    expect(
      find.byKey(ValueKey('calendar-week-event-2026-10-16-${created.id}')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, database);
  });
}
