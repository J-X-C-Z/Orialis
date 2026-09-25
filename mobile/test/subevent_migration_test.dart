import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';

void main() {
  test(
    'v6 data migrates to v9 with empty task links and unimportant events',
    () async {
      final fixture = File('test/fixtures/schema_v6.sql').readAsStringSync();
      final database = AppDatabase(
        executor: NativeDatabase.memory(
          setup: (sqlite) => sqlite.execute(fixture),
        ),
      );
      addTearDown(database.close);

      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 9);

      final oldTask = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('old-task'))).getSingle();
      expect(oldTask.parentTaskId, equals(null));
      expect(oldTask.scheduleId, equals(null));
      expect(oldTask.projectId, 'p1');

      final oldEvent = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals('old-event'))).getSingle();
      expect(oldEvent.important, isFalse);
      expect(oldEvent.reminderMinutes, 30);

      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'child-task',
              title: 'Child task',
              parentTaskId: const Value('old-task'),
              createdAt: '2026-09-17T00:00:00Z',
              updatedAt: '2026-09-17T00:00:00Z',
            ),
          );
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'scheduled-task',
              title: 'Scheduled task',
              scheduleId: const Value('old-event'),
              createdAt: '2026-09-17T00:00:00Z',
              updatedAt: '2026-09-17T00:00:00Z',
            ),
          );
      await (database.update(database.calendarEvents)
            ..where((row) => row.id.equals('old-event')))
          .write(const CalendarEventsCompanion(important: Value(true)));

      final child = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('child-task'))).getSingle();
      expect(child.parentTaskId, 'old-task');
      expect(child.scheduleId, equals(null));
      final scheduled = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('scheduled-task'))).getSingle();
      expect(scheduled.parentTaskId, equals(null));
      expect(scheduled.scheduleId, 'old-event');
      expect(
        (await (database.select(
          database.calendarEvents,
        )..where((row) => row.id.equals('old-event'))).getSingle()).important,
        isTrue,
      );
    },
  );
}
