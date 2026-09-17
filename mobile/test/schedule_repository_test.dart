import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/events/data/schedule_repository.dart';

void main() {
  test('ScheduleRepository create preserves all schedule fields', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ScheduleRepository(
      delegate: EventRepository(database: database, config: AppConfig()),
    );
    final start = DateTime.utc(2026, 9, 20, 9);
    final end = DateTime.utc(2026, 9, 20, 10);

    await repository.create(
      title: '评审',
      startAt: start,
      endAt: end,
      allDay: true,
      location: '会议室',
      description: '准备材料',
      reminderMinutes: 15,
    );

    final event = await database.select(database.calendarEvents).getSingle();
    expect(event.title, '评审');
    expect(event.allDay, isTrue);
    expect(event.location, '会议室');
    expect(event.description, '准备材料');
    expect(event.reminderMinutes, 15);
    expect(event.startAt, start.toIso8601String());
    expect(event.endAt, end.toIso8601String());
  });

  test('ScheduleRepository rejects invalid time range and reminder', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ScheduleRepository(
      delegate: EventRepository(database: database, config: AppConfig()),
    );
    final start = DateTime.utc(2026, 9, 20, 10);

    expect(
      () => repository.create(
        title: '无效',
        startAt: start,
        endAt: start,
        reminderMinutes: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.create(
        title: '无效提醒',
        startAt: start,
        endAt: start.add(const Duration(hours: 1)),
        reminderMinutes: -1,
      ),
      throwsArgumentError,
    );
  });
}
