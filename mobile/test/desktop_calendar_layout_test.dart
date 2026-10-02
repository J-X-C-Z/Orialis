import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/pages/calendar/calendar_page.dart';

class _CalendarConfig extends AppConfig {
  @override
  Future<String> deviceId() async => 'desktop-calendar-test';
}

Widget _calendar(AppDatabase database, {bool desktop = true}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(_CalendarConfig()),
    desktopModeProvider.overrideWithValue(desktop),
  ],
  child: WidgetsApp(
    color: const Color(0xff000000),
    builder: (context, _) => LuminaTheme(
      child: DefaultTextStyle(
        style: const LuminaTextTheme(LuminaColors(dark: false)).bodyMedium,
        child: Navigator(
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (_, a, b) => DesktopLayoutScope(
              child: CalendarPage(initialDate: DateTime(2026, 10, 15)),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('desktop month keeps selected agenda beside its calendar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = AppDatabase(executor: NativeDatabase.memory());
    final events = EventRepository(
      database: database,
      config: _CalendarConfig(),
    );
    for (var i = 0; i < 12; i++) {
      await events.createCalendarEvent(
        title: '日程 $i',
        startAt: DateTime(2026, 10, 15, 8 + i),
        endAt: DateTime(2026, 10, 15, 9 + i),
      );
    }
    await events.createTask(title: '次日截止任务', due: '2026-10-16');
    await tester.pumpWidget(_calendar(database));
    await tester.pumpAndSettle();
    final grid = find.byKey(const PageStorageKey('desktop-calendar-grid'));
    final agenda = find.byKey(const PageStorageKey('desktop-calendar-agenda'));
    expect(tester.getRect(grid).right, lessThan(tester.getRect(agenda).left));
    final cell = find.byKey(const ValueKey('desktop-calendar-date-2026-10-15'));
    final cellPosition = tester.getTopLeft(cell);
    await tester.drag(agenda, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(cell), cellPosition);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('desktop-calendar-date-2026-10-16')),
    );
    await tester.pumpAndSettle();
    await tester.drag(agenda, const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(find.text('10月16日 · 日程'), findsOneWidget);
    final complete = find.descendant(
      of: agenda,
      matching: find.byType(LuminaCheck),
    );
    await tester.tap(complete);
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.tasks).get()).single.completed,
      isTrue,
    );

    for (final view in ['周', '日', '月']) {
      await tester.tap(find.text(view).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(840, 800);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-calendar-split')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(560, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-calendar-split')), findsNothing);
    expect(
      find.byKey(const PageStorageKey('calendar-month-scroll')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await database.close();
  });

  testWidgets('wide mobile mode retains the original calendar layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = AppDatabase(executor: NativeDatabase.memory());
    await tester.pumpWidget(_calendar(database, desktop: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-calendar-split')), findsNothing);
    expect(
      find.byKey(const PageStorageKey('calendar-month-scroll')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await database.close();
  });
}
