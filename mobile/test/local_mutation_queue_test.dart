import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

void main() {
  test('editing a local task keeps it on the create path', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = EventRepository(database: database, config: AppConfig());

    await repository.createTask(title: '本地任务');
    final task = await database.select(database.tasks).getSingle();
    await repository.completeTask(task, true);

    final updated = await database.select(database.tasks).getSingle();
    expect(updated.syncStatus, 'pendingCreate');
    expect(updated.completed, isTrue);
    // The completion timestamp is selected by the server, not synthesized by
    // the offline client.
    expect(updated.completedAt, isNull);
  });

  test('editing a local schedule keeps it on the create path', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = EventRepository(database: database, config: AppConfig());
    final start = DateTime.utc(2026, 9, 17, 9);
    final end = start.add(const Duration(hours: 1));

    await repository.createCalendarEvent(
      title: '本地日程',
      startAt: start,
      endAt: end,
    );
    final event = await database.select(database.calendarEvents).getSingle();
    await repository.updateSchedule(
      event,
      title: '本地日程（已改）',
      startAt: start,
      endAt: end,
    );

    final updated = await database.select(database.calendarEvents).getSingle();
    expect(updated.syncStatus, 'pendingCreate');
    expect(updated.title, '本地日程（已改）');
  });
}
