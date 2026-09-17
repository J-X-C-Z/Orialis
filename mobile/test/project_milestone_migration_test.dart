import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';

const timestamp = '2026-09-17T00:00:00Z';

Map<String, Object?> columnValues(Insertable<Object?> row) => row
    .toColumns(false)
    .map((key, value) => MapEntry(key, (value as Variable).value));

void main() {
  test('v6 upgrades to v8 without changing existing data or outbox', () async {
    final fixture = File('test/fixtures/schema_v6.sql').readAsStringSync();
    final database = AppDatabase(
      executor: NativeDatabase.memory(
        setup: (sqlite) => sqlite.execute(fixture),
      ),
    );
    addTearDown(database.close);

    expect(await database.select(database.projects).get(), isEmpty);
    expect(await database.select(database.projectMilestones).get(), isEmpty);
    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(version.read<int>('user_version'), 8);
    final indexes = await database
        .customSelect(
          "PRAGMA index_info('idx_project_milestones_project_position')",
        )
        .get();
    expect(indexes.map((row) => row.read<String>('name')), [
      'project_id',
      'deleted_at',
      'position',
      'id',
    ]);

    final task = await database.select(database.tasks).getSingle();
    expect(task.projectId, 'p1');
    expect(task.reminderMinutes, 15);
    expect([task.version, task.remoteVersion, task.localRevision], [4, 3, 8]);
    expect(task.syncStatus, 'pendingUpdate');
    final event = await database.select(database.calendarEvents).getSingle();
    expect(event.reminderMinutes, 30);
    expect(
      [event.version, event.remoteVersion, event.localRevision],
      [2, 2, 5],
    );
    final mutation = await database
        .select(database.outboxMutations)
        .getSingle();
    expect(mutation.mutationId, 'stable-mutation');
    expect(mutation.payloadJson, '{"title":"queued task"}');
    expect(mutation.baseVersion, 3);
    expect(mutation.entityRevision, 8);
    expect(mutation.status, 'inFlight');
    expect(mutation.attemptCount, 2);
    expect(mutation.lastError, 'timeout');
    expect(
      (await database.select(database.syncMetadata).getSingle()).value,
      '42',
    );
    expect(
      (await database.select(database.messages).getSingle()).content,
      'keep me',
    );
    expect(
      (await database.select(database.conversations).getSingle()).id,
      'c1',
    );
  });

  test(
    'v7 fields round-trip and active milestones have stable ordering',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final project = ProjectsCompanion.insert(
        id: 'p1',
        name: 'Project',
        goal: const Value('Goal'),
        description: const Value('Description'),
        color: const Value('#0088ff'),
        status: const Value('archived'),
        startDate: const Value('2026-09-17'),
        due: const Value('2026-10-01'),
        nextActionTaskId: const Value('task1'),
        version: const Value(5),
        remoteVersion: const Value(4),
        localRevision: const Value(9),
        syncStatus: const Value('pendingUpdate'),
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      await database.into(database.projects).insert(project);
      final stored = await database.select(database.projects).getSingle();
      expect(columnValues(stored), {
        ...columnValues(project),
        'deleted_at': null,
      });
      for (final entry in [
        ('b', 2, null),
        ('a', 2, null),
        ('c', 1, null),
        ('deleted', 0, timestamp),
      ]) {
        final milestone = ProjectMilestonesCompanion.insert(
          id: entry.$1,
          projectId: 'p1',
          title: 'Milestone ${entry.$1}',
          due: const Value('2026-09-30'),
          completed: const Value(true),
          completedAt: const Value(timestamp),
          position: Value(entry.$2),
          version: const Value(3),
          remoteVersion: const Value(2),
          localRevision: const Value(7),
          syncStatus: const Value('pendingUpdate'),
          deletedAt: Value(entry.$3),
          createdAt: timestamp,
          updatedAt: timestamp,
        );
        await database.into(database.projectMilestones).insert(milestone);
        final row = await (database.select(
          database.projectMilestones,
        )..where((row) => row.id.equals(entry.$1))).getSingle();
        expect(columnValues(row), columnValues(milestone));
      }
      expect(
        (await database.watchActiveProjectMilestones('p1').first).map(
          (row) => row.id,
        ),
        ['c', 'a', 'b'],
      );
      expect(
        await database.watchActiveProjectMilestones('other').first,
        isEmpty,
      );
      expect((await database.watchActiveProjects().first).single.id, 'p1');
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );
}
