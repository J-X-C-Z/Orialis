import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';
import 'package:orialis_mobile/pages/calendar/calendar_page.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';
import 'package:orialis_mobile/pages/projects/projects_page.dart';
import 'package:orialis_mobile/pages/shared/adaptive_layout.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';
import 'package:orialis_mobile/pages/today/today_page.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'adaptive-content-test';
}

Future<void> _show(
  WidgetTester tester,
  AppDatabase db,
  Widget page, {
  double textScale = 1,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => page),
      GoRoute(path: '/events', builder: (_, _) => const Text('全部任务已打开')),
      GoRoute(path: '/calendar', builder: (_, _) => const Text('日历已打开')),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appConfigProvider.overrideWithValue(_Config()),
        desktopModeProvider.overrideWithValue(false),
      ],
      child: WidgetsApp.router(
        color: const Color(0xffeeeeee),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: LuminaTheme(
            child: DefaultTextStyle(
              style: const LuminaTextTheme(LuminaColors(dark: false))
                  .bodyMedium,
              child: LayoutBuilder(
                builder: (context, constraints) => OrialisAdaptiveLayout(
                  wide: constraints.maxWidth >= 600,
                  tablet: MediaQuery.sizeOf(context).shortestSide >= 600,
                  navigationWidth: constraints.maxWidth >= 600 ? 88 : 0,
                  child: child!,
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

void _expectAxis<T>(
  WidgetTester tester,
  Finder selector,
  List<String> labels,
  bool vertical,
) {
  final widget = tester.widget<OrialisGlassSegmented<T>>(selector);
  expect(widget.direction, vertical ? Axis.vertical : Axis.horizontal);
  final frames = [
    for (final label in labels)
      tester.getRect(
        find.descendant(
          of: selector,
          matching: find.text(vertical ? label.split('').join('\n') : label),
        ),
      ),
  ];
  for (var i = 1; i < frames.length; i++) {
    if (vertical) {
      expect(frames[i].top, greaterThan(frames[i - 1].bottom));
      expect(frames[i].center.dx, closeTo(frames[0].center.dx, .1));
    } else {
      expect(frames[i].left, greaterThan(frames[i - 1].right));
    }
  }
  expect(
    find.descendant(of: selector, matching: find.byType(RotatedBox)),
    findsNothing,
  );
}

void main() {
  for (final size in [
    const Size(720, 390),
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(390, 844),
    const Size(320, 844),
  ]) {
    testWidgets('mobile content adapts without desktop services at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(executor: NativeDatabase.memory());
      final events = EventRepository(database: db, config: _Config());
      await events.createTask(title: '平板事项', important: true, urgent: true);
      await events.createCalendarEvent(
        title: '左日期右日程',
        startAt: DateTime(2026, 11, 2, 9),
        endAt: DateTime(2026, 11, 2, 10),
      );
      await events.createCalendarEvent(
        title: '翌日日程',
        startAt: DateTime(2026, 11, 3, 9),
        endAt: DateTime(2026, 11, 3, 10),
      );

      final repository = ProjectRepository(db);
      final project = await repository.createProject(
        name: '平板项目',
        goal: '保留项目操作',
      );
      await repository.createMilestone(projectId: project.id, title: '可完成里程碑');
      await _show(tester, db, const TodayPage());
      expect(
        find.byKey(const ValueKey('desktop-today-columns')),
        size.width >= 600 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _show(tester, db, CalendarPage(initialDate: DateTime(2026, 11, 2)));
      final wide = size.width >= 600;
      _expectAxis<int>(
        tester,
        find.byKey(const ValueKey('calendar-view-selector')),
        ['日', '周', '月'],
        wide,
      );
      final split = find.byKey(const ValueKey('adaptive-calendar-split'));
      expect(split, wide ? findsOneWidget : findsNothing);
      if (wide) {
        final dateCell = find.byKey(
          const ValueKey('calendar-date-month-2026-11-03'),
        );
        expect(tester.getSize(dateCell).width, greaterThanOrEqualTo(39));
        expect(tester.getSize(dateCell).height, greaterThanOrEqualTo(47.9));
        final dayLabel = tester.getRect(
          find.descendant(of: dateCell, matching: find.text('3')),
        );
        expect(tester.getRect(dateCell).contains(dayLabel.topLeft), isTrue);
        expect(tester.getRect(dateCell).contains(dayLabel.bottomRight), isTrue);
        final grid = find.byKey(const PageStorageKey('adaptive-calendar-grid'));
        final agenda = find.byKey(
          const PageStorageKey('adaptive-calendar-agenda-2026-11-02'),
        );
        expect(
          tester.getRect(grid).right,
          lessThan(tester.getRect(agenda).left),
        );
        if (size.width == 844) {
          expect(
            tester.getSize(grid).width,
            lessThan(tester.getSize(agenda).width),
          );
        }
        expect(tester.getSize(grid).width, lessThanOrEqualTo(400));
        if (size.width == 720) {
          final card = find.ancestor(
            of: find.text('左日期右日程'),
            matching: find.byType(LuminaListRow),
          );
          final heading = find.text('11月2日 · 日程');
          final time = find.text('09:00 — 10:00');
          expect(
            tester.getSize(card).width,
            closeTo(tester.getSize(heading).width, .1),
          );
          expect(
            tester.getRect(time).bottom,
            lessThan(tester.getRect(card).top),
          );
        }
        await tester.tap(dateCell);
        await tester.pumpAndSettle();
        expect(find.text('翌日日程'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('calendar-view-selector')),
            matching: find.text('日'),
          ),
        );
        await tester.pumpAndSettle();
        expect(split, findsOneWidget);
      }
      await tester.tap(find.text('周').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-week-timeline')),
        findsOneWidget,
      );
      if (wide) {
        expect(
          tester
              .getRect(find.byKey(const ValueKey('calendar-controls-card')))
              .right,
          lessThan(
            tester
                .getRect(find.byKey(const ValueKey('calendar-week-timeline')))
                .left,
          ),
        );
      }
      expect(tester.takeException(), isNull);
      await _show(tester, db, const EventsPage());
      expect(find.text('平板事项'), findsOneWidget);
      _expectAxis<int>(
        tester,
        find.byKey(const ValueKey('events-mode-selector')),
        ['四象限', '项目'],
        wide,
      );
      _expectAxis<String>(
        tester,
        find.byKey(const ValueKey('events-filter-selector')),
        ['待完成', '无截止', '已完成'],
        wide,
      );

      expect(
        find.byKey(const ValueKey('adaptive-task-columns')),
        wide ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('events-mode-selector')),
          matching: find.text(wide ? '项\n目' : '项目'),
        ),
      );
      await tester.pumpAndSettle();
      _expectAxis<String>(
        tester,
        find.byKey(const ValueKey('events-project-status-filter')),
        ['未开始', '进行中', '已完成'],
        wide,
      );
      await _show(tester, db, const ProjectsPage(embedded: true));
      if (size.width >= 1200) {
        final row = find.byKey(ValueKey('desktop-project:${project.id}'));
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('可完成里程碑'), findsOneWidget);
        expect(
          tester.getRect(row).right,
          lessThan(
            tester
                .getRect(find.byKey(const ValueKey('desktop-project-detail')))
                .left,
          ),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await db.close();
    });
  }
  testWidgets('landscape Today keeps task and navigation actions usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(executor: NativeDatabase.memory());
    final events = EventRepository(database: db, config: _Config());
    await events.createTask(title: '横屏可完成任务', important: true, urgent: true);
    await _show(tester, db, const TodayPage());
    final focus = find.byKey(const PageStorageKey('today-focus-scroll'));
    final agenda = find.byKey(const PageStorageKey('today-agenda-scroll'));
    expect(tester.getRect(focus).right, lessThan(tester.getRect(agenda).left));
    expect(
      tester.getSize(focus).width,
      closeTo(tester.getSize(agenda).width, .1),
    );
    final task = find.ancestor(
      of: find.text('横屏可完成任务'),
      matching: find.byType(LuminaListRow),
    );
    await tester.tap(
      find.descendant(of: task, matching: find.byType(LuminaCheck)),
    );
    await tester.pumpAndSettle();
    expect((await db.select(db.tasks).getSingle()).completed, isTrue);
    await tester.tap(find.text('全部任务'));
    await tester.pumpAndSettle();
    expect(find.text('全部任务已打开'), findsOneWidget);
    await _show(tester, db, const TodayPage());
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.text('日历已打开'), findsOneWidget);
    await _show(tester, db, const TodayPage(), textScale: 1.8);
    expect(find.byKey(const ValueKey('desktop-today-columns')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });
}
