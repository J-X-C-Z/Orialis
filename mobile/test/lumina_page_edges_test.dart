import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://127.0.0.1:1';
  @override
  Future<String> deviceId() async => 'edge-test';
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
}

class _Offline extends SyncCoordinator {
  _Offline({required super.realtime, required super.chatRepository})
    : super(sync: () async => SyncState.offline);
  @override
  Future<void> start() async {}
}

Widget _app(AppDatabase db) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(db),
    appConfigProvider.overrideWithValue(_Config()),
    syncCoordinatorProvider.overrideWith(
      (ref) => _Offline(
        realtime: ref.read(realtimeClientProvider),
        chatRepository: ref.read(chatRepositoryProvider),
      ),
    ),
  ],
  child: const OrialisApp(),
);
void main() {
  testWidgets('schedule details create an attached task for that occurrence', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    final now = DateTime.now();
    await EventRepository(database: db, config: _Config()).createCalendarEvent(
      title: '本次物理课',
      startAt: DateTime(now.year, now.month, now.day, 10),
      endAt: DateTime(now.year, now.month, now.day, 11),
    );
    final schedule = (await db.select(db.calendarEvents).get()).single;
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本次物理课'));
    await tester.pumpAndSettle();
    final add = find.byWidgetPredicate(
      (w) => w is LuminaIconButton && w.tooltip == '添加子事件',
    );
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final title = find
        .byWidgetPredicate((w) => w is LuminaTextField && w.label == '标题')
        .last;
    await tester.enterText(
      find.descendant(of: title, matching: find.byType(EditableText)),
      '课后作业',
    );
    final save = find.widgetWithText(LuminaButton, '保存').last;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final child = (await db.select(db.tasks).get()).single;
    expect(child.scheduleId, schedule.id);
    expect(child.parentTaskId, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });

  testWidgets('child task can be created from its parent editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    await EventRepository(
      database: db,
      config: _Config(),
    ).createTask(title: '课前准备', important: true, urgent: true);
    final parent = (await db.select(db.tasks).get()).single;
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课前准备'));
    await tester.pumpAndSettle();
    final add = find.byWidgetPredicate(
      (w) => w is LuminaIconButton && w.tooltip == '添加子事件',
    );
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final titleField = find
        .byWidgetPredicate((w) => w is LuminaTextField && w.label == '标题')
        .last;
    await tester.enterText(
      find.descendant(of: titleField, matching: find.byType(EditableText)),
      '完成练习题',
    );
    final save = find.widgetWithText(LuminaButton, '保存').last;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final child = (await db.select(db.tasks).get()).singleWhere(
      (t) => t.title == '完成练习题',
    );
    expect(child.parentTaskId, parent.id);
    expect(child.scheduleId, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });

  testWidgets('long event filter travel changes only endpoint content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    final repository = EventRepository(database: db, config: _Config());
    await repository.createTask(title: '无截止待办');
    await repository.createTask(title: '已经完成的事项');
    final completed = (await db.select(db.tasks).get()).singleWhere(
      (task) => task.title == '已经完成的事项',
    );
    await repository.completeTask(completed, true);
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();
    expect(find.text('已经完成的事项'), findsOneWidget);
    expect(find.text('无截止待办'), findsNothing);

    await tester.tap(find.text('待完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(
      tester
          .widget<LuminaSegmented<String>>(find.byType(LuminaSegmented<String>))
          .value,
      'active',
    );
    expect(find.text('已经完成的事项'), findsOneWidget);
    expect(find.text('无截止待办'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('无截止待办'), findsOneWidget);
    expect(find.text('已经完成的事项'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });

  testWidgets('last unclassified item stays visible through completion exit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    await EventRepository(
      database: db,
      config: _Config(),
    ).createTask(title: '未分类事项');
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件').last);
    await tester.pumpAndSettle();
    final title = find.text('未分类事项');
    final eventsList = find
        .ancestor(of: title, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(title, 220, scrollable: eventsList);
    final row = find
        .ancestor(of: title, matching: find.byType(LuminaCompletionList))
        .first;
    await tester.tap(
      find.descendant(of: row, matching: find.byType(LuminaCheck)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(title, findsOneWidget);
    await tester.pumpAndSettle();
    expect(title, findsNothing);
    expect((await db.select(db.tasks).get()).single.completed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });

  testWidgets(
    'editing an all-day schedule without changes preserves exclusive end',
    (tester) async {
      tester.view.physicalSize = const Size(432, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(executor: NativeDatabase.memory());
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = DateTime(now.year, now.month, now.day + 1);
      await EventRepository(
        database: db,
        config: _Config(),
      ).createCalendarEvent(
        title: '全天保留测试',
        startAt: start,
        endAt: end,
        allDay: true,
      );
      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日历').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全天保留测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(LuminaButton, '编辑日程'));
      await tester.pumpAndSettle();
      final save = find.widgetWithText(LuminaButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final event = (await db.select(db.calendarEvents).get()).single;
      expect(DateTime.parse(event.endAt), end.toUtc());
      expect(DateTime.parse(event.startAt), start.toUtc());
      expect(event.allDay, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await db.close();
    },
  );
  testWidgets('320dp with 2x text supports destinations and calendar views', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = AppDatabase(executor: NativeDatabase.memory());
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final destination in ['事件', '日历', '我的']) {
      await tester.tap(find.text(destination).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: destination);
      if (destination == '日历') {
        for (final view in ['周', '月', '日']) {
          await tester.tap(find.text(view).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: view);
          if (view == '月') {
            final expand = find.text('展开月历');
            await tester.ensureVisible(expand);
            await tester.pumpAndSettle();
            await tester.tap(expand);
            await tester.pumpAndSettle();
            final collapse = find.text('收起月历');
            await tester.ensureVisible(collapse);
            await tester.pumpAndSettle();
            await tester.tap(collapse);
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LuminaSegmented<int>>(
                    find.byType(LuminaSegmented<int>),
                  )
                  .value,
              2,
            );
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });
  testWidgets('weekly schedule rows use the recessed card treatment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    final today = DateTime.now();
    await EventRepository(database: db, config: _Config()).createCalendarEvent(
      title: '周视图凹陷日程',
      startAt: DateTime(today.year, today.month, today.day, 10),
      endAt: DateTime(today.year, today.month, today.day, 11),
    );
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日历').last);
    await tester.pumpAndSettle();
    final dateTiles = find.byWidgetPredicate(
      (w) =>
          w is LuminaSurface &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('calendar-date-month-'),
    );
    final sizes = dateTiles
        .evaluate()
        .map((e) => tester.getSize(find.byWidget(e.widget)))
        .toList();
    expect(sizes, isNotEmpty);
    for (final size in sizes) {
      expect(size.width, closeTo(sizes.first.width, .1));
      expect(size.height, sizes.first.height);
    }
    for (final tile in tester.widgetList<LuminaSurface>(dateTiles)) {
      expect(tile.glass, isTrue);
      expect(tile.onTap, isNotNull);
    }
    await tester.tap(find.text('周').first);
    await tester.pumpAndSettle();
    final row = tester.widget<OrialisListRow>(
      find.widgetWithText(OrialisListRow, '周视图凹陷日程'),
    );
    expect(row.depth, LuminaSurfaceDepth.recessed);
    expect(
      find.ancestor(
        of: find.widgetWithText(OrialisListRow, '周视图凹陷日程'),
        matching: find.byType(LuminaCollapsibleCard),
      ),
      findsOneWidget,
    );
    expect(find.text('附属事件'), findsNothing);
    await tester.tap(find.text('日').first);
    await tester.pumpAndSettle();
    expect(find.text('附属事件'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is LuminaCollapsibleCard &&
            w.storageId.startsWith('calendar.schedule.'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });

  testWidgets('today nests recessed tasks and quadrants scroll in one column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(executor: NativeDatabase.memory());
    final repository = EventRepository(database: db, config: _Config());
    for (var i = 0; i < 8; i++) {
      await repository.createTask(
        title: '重点事项 $i',
        important: true,
        urgent: true,
      );
    }
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    final focus = tester.widget<OrialisSection>(
      find.widgetWithText(OrialisSection, '现在关注'),
    );
    expect(focus.raised, isTrue);
    final task = tester.widget<OrialisListRow>(
      find.widgetWithText(OrialisListRow, '重点事项 0'),
    );
    expect(task.depth, LuminaSurfaceDepth.recessed);
    final cardTitle = tester.widget<Text>(find.text('现在关注'));
    expect(cardTitle.style?.fontSize, 18);
    expect(tester.widget<Text>(find.text('最近截止')).style?.fontSize, 18);
    final todayTitleX = tester.getTopLeft(find.text('现在关注')).dx;
    expect(tester.getTopLeft(find.text('最近截止')).dx, closeTo(todayTitleX, 1));
    expect(tester.widget<Text>(find.text('重点事项 0')).style?.fontSize, 16);

    await tester.tap(find.text('事件').last);
    await tester.pumpAndSettle();
    final first = find.text('重要且紧急');
    final second = find.text('紧急但不重要');
    expect(tester.widget<Text>(first).style?.fontSize, 18);
    expect(tester.getTopLeft(first).dx, closeTo(todayTitleX, 1));
    expect(tester.widget<Text>(find.text('重点事项 0')).style?.fontSize, 16);
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: first,
                  matching: find.byType(LuminaCollapsibleCard),
                )
                .first,
          )
          .width,
      greaterThan(380),
    );
    final list = find
        .ancestor(of: first, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(second, 260, scrollable: list);
    expect(find.text('紧急但不重要'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('重点事项 7'),
      -260,
      scrollable: list,
    );
    expect(find.text('重点事项 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });
}
