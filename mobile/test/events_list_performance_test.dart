import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/presentation/task_quadrant.dart';
import 'package:orialis_mobile/features/events/presentation/task_quadrant_sliver.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';

void main() {
  setUp(() => LuminaCardMemory.store = LuminaMemoryCardStore());

  Future<AppDatabase> mount(WidgetTester tester, {int count = 1000}) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = AppDatabase(executor: NativeDatabase.memory());
    await database.batch((batch) {
      batch.insertAll(database.tasks, [
        for (var i = 0; i < count; i++)
          TasksCompanion.insert(
            id: 'task-$i',
            title: '流畅度任务 $i',
            important: const Value(true),
            urgent: const Value(true),
            manualPosition: Value(i),
            createdAt: '2026-10-24',
            updatedAt: '2026-10-24',
          ),
      ]);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MaterialApp(home: LuminaTheme(child: EventsPage())),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(database.close);
    return database;
  }

  Finder firstQuadrant() => find.byWidgetPredicate(
    (widget) =>
        widget is TaskQuadrantSliver &&
        widget.quadrant == TaskQuadrant.urgentImportant,
  );

  testWidgets('thousand-task quadrant builds only viewport rows and scrolls', (
    tester,
  ) async {
    final database = await mount(tester);
    final rows = find.byType(LuminaLongPressOrderable<Task>);
    expect(rows.evaluate().length, inExclusiveRange(0, 40));
    expect(find.text('流畅度任务 999'), findsNothing);
    expect(find.text('流畅度任务 0'), findsOneWidget);
    final scroll = find.descendant(
      of: find.byType(CustomScrollView).first,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scroll.first).position;
    position.jumpTo(4000);
    await tester.pumpAndSettle();
    expect(rows.evaluate().length, lessThan(40));
    expect(find.text('流畅度任务 0'), findsNothing);
    position.jumpTo(0);
    await tester.pumpAndSettle();
    final extent = tester
        .renderObject<RenderSliver>(firstQuadrant())
        .geometry!
        .scrollExtent;
    await tester.tap(find.text('重要且紧急'));
    await tester.pump();
    await tester.pump(
      Duration(microseconds: LuminaMotion.standard.inMicroseconds ~/ 2),
    );
    final foldingExtent = tester
        .renderObject<RenderSliver>(firstQuadrant())
        .geometry!
        .scrollExtent;
    expect(foldingExtent, lessThan(extent));
    expect(foldingExtent, greaterThan(100));
    await tester.pumpAndSettle();
    expect(find.text('事项已收起'), findsOneWidget);
    await tester.runAsync(
      () =>
          (database.update(database.tasks)
                ..where((task) => task.id.equals('task-0')))
              .write(const TasksCompanion(title: Value('折叠期间更新的任务'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重要且紧急'));
    await tester.pumpAndSettle();
    expect(find.text('折叠期间更新的任务'), findsOneWidget);
    expect(rows.evaluate().length, lessThan(40));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('remembered collapsed quadrant does not build task rows', (
    tester,
  ) async {
    LuminaCardMemory.save('quadrant:urgentImportant', false);
    await mount(tester);
    expect(find.byType(LuminaLongPressOrderable<Task>), findsNothing);
    expect(find.text('事项已收起'), findsOneWidget);
    await tester.tap(find.text('重要且紧急'));
    await tester.pumpAndSettle();
    expect(
      find.byType(LuminaLongPressOrderable<Task>).evaluate().length,
      inExclusiveRange(0, 40),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
