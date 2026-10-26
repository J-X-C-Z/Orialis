import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/pages/shared/desktop_insights.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

Widget _app(AppDatabase database, {double textScale = 1}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(AppConfig()),
  ],
  child: MaterialApp(
    color: const Color(0xff000000),
    builder: (context, child) => LuminaTheme(
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: DefaultTextStyle(
          style: const LuminaTextTheme().bodyMedium,
          child: child!,
        ),
      ),
    ),
    home: const Center(
      child: SizedBox(width: 280, child: DesktopInsightsPanel()),
    ),
  ),
);

void main() {
  testWidgets(
    'empty local data has explicit empty states without fake charts',
    (tester) async {
      final database = AppDatabase(executor: NativeDatabase.memory());

      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_app(database));
        await tester.pumpAndSettle();

        expect(find.text('还没有任务'), findsOneWidget);
        expect(find.text('暂无未完成任务'), findsOneWidget);
        expect(find.text('没有即将开始的日程'), findsOneWidget);
        expect(find.bySemanticsLabel('任务完成进度'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        semantics.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'live summaries count real tasks and show the next three schedules',
    (tester) async {
      tester.view.physicalSize = const Size(840, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = AppDatabase(executor: NativeDatabase.memory());
      final events = EventRepository(database: database, config: AppConfig());
      await events.createTask(title: '已完成', important: true, urgent: true);
      await events.createTask(title: '双高任务', important: true, urgent: true);
      await events.createTask(title: '重要任务', important: true, urgent: false);
      await events.createTask(title: '紧急任务', important: false, urgent: true);
      await events.createTask(title: '普通任务', important: false, urgent: false);
      await events.createTask(title: '未分类任务', important: null, urgent: false);
      final tasks = await database.select(database.tasks).get();
      await events.completeTask(
        tasks.firstWhere((task) => task.title == '已完成'),
        true,
      );

      final now = DateTime.now();
      Future<void> addSchedule(
        String title,
        DateTime start,
        DateTime end, {
        bool allDay = false,
      }) => events.createCalendarEvent(
        title: title,
        startAt: start,
        endAt: end,
        allDay: allDay,
      );

      await addSchedule(
        '过去的日程',
        now.subtract(const Duration(hours: 3)),
        now.subtract(const Duration(hours: 2)),
      );
      await addSchedule(
        '最近日程',
        now.add(const Duration(hours: 1)),
        now.add(const Duration(hours: 2)),
      );
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      await addSchedule(
        '全天安排',
        DateTime(now.year, now.month, now.day),
        tomorrow,
        allDay: true,
      );
      await addSchedule(
        '第三条日程',
        now.add(const Duration(hours: 3)),
        now.add(const Duration(hours: 4)),
      );
      await addSchedule(
        '第四条日程',
        now.add(const Duration(hours: 5)),
        now.add(const Duration(hours: 6)),
      );

      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_app(database, textScale: 2));
        await tester.pumpAndSettle();
        expect(find.text('已完成 1 / 6 项'), findsOneWidget);
        expect(find.text('重要且紧急'), findsOneWidget);
        expect(find.text('只重要'), findsOneWidget);
        expect(find.text('只紧急'), findsOneWidget);
        expect(find.text('普通'), findsOneWidget);
        expect(find.text('未分类'), findsOneWidget);
        expect(find.text('最近日程'), findsOneWidget);
        expect(find.text('全天安排'), findsOneWidget);
        expect(find.text('第三条日程'), findsOneWidget);
        expect(find.text('第四条日程'), findsNothing);
        expect(find.text('过去的日程'), findsNothing);
        expect(find.text('全天'), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel('任务完成进度')).value,
          '已完成 1 项，共 6 项',
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('未完成任务象限分布')).value,
          '重要且紧急 1 项，只重要 1 项，只紧急 1 项，普通 1 项，未分类 1 项',
        );
        expect(tester.takeException(), isNull);

        await addSchedule(
          '刚加入的日程',
          now.add(const Duration(minutes: 30)),
          now.add(const Duration(hours: 1)),
        );
        await tester.pumpAndSettle();
        expect(find.text('刚加入的日程'), findsOneWidget);

        await events.createTask(title: '新任务', important: true, urgent: true);
        await tester.pumpAndSettle();
        expect(find.text('已完成 1 / 7 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        semantics.dispose();
        await database.close();
      }
    },
  );
}
