import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

AppDatabase openDatabase(String path) =>
    AppDatabase(executor: NativeDatabase(File(path)));

void createV5Fixture(dynamic sqlite) {
  sqlite.execute('''
    CREATE TABLE tasks (
      id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, notes TEXT,
      due TEXT, due_time TEXT, important INTEGER, urgent INTEGER,
      completed INTEGER NOT NULL DEFAULT 0, completed_at TEXT,
      project_id TEXT, recurrence TEXT, version INTEGER NOT NULL DEFAULT 1,
      remote_version INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, deleted_at TEXT,
      sync_status TEXT NOT NULL DEFAULT 'synced'
    )
  ''');
  sqlite.execute('''
    CREATE TABLE calendar_events (
      id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, description TEXT,
      location TEXT, start_at TEXT NOT NULL, end_at TEXT NOT NULL,
      all_day INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 1,
      remote_version INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, deleted_at TEXT,
      sync_status TEXT NOT NULL DEFAULT 'synced'
    )
  ''');
  sqlite.execute('''
    CREATE TABLE messages (
      conversation_id TEXT NOT NULL, id TEXT NOT NULL, role TEXT NOT NULL,
      content TEXT NOT NULL, created_at TEXT NOT NULL,
      sync_status TEXT NOT NULL DEFAULT 'synced',
      remote_version INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (conversation_id, id)
    )
  ''');
  sqlite.execute('''
    CREATE TABLE conversations (
      id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'normal', created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
      remote_version INTEGER NOT NULL DEFAULT 0, deleted_at TEXT,
      sync_status TEXT NOT NULL DEFAULT 'synced'
    )
  ''');
  sqlite.execute(
    'CREATE TABLE sync_metadata (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
  );
  sqlite.execute('''
    INSERT INTO tasks (
      id, title, important, urgent, recurrence, created_at, updated_at
    ) VALUES (
      'legacy-task', '旧任务', NULL, 1,
      '{"rule":"FREQ=DAILY","until":"2026-12-31"}',
      '2026-09-17T00:00:00.000Z', '2026-09-17T00:00:00.000Z'
    )
  ''');
  sqlite.execute('''
    INSERT INTO calendar_events (
      id, title, description, location, start_at, end_at, created_at, updated_at
    ) VALUES (
      'legacy-schedule', '旧日程', '说明', '地点',
      '2026-09-18T01:00:00.000Z', '2026-09-18T02:00:00.000Z',
      '2026-09-17T00:00:00.000Z', '2026-09-17T00:00:00.000Z'
    )
  ''');
  sqlite.execute('PRAGMA user_version = 5');
}

void main() {
  test('nullable task priority and recurrence survive local storage', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = EventRepository(database: database, config: AppConfig());

    await repository.createTask(
      title: '未分类任务',
      due: '2026-09-20',
      dueTime: '23:59',
      recurrence: const TaskRecurrence(
        rule: 'FREQ=WEEKLY;BYDAY=MO',
        until: '2026-12-31',
      ),
    );

    final task = await database.select(database.tasks).getSingle();
    expect(task.important, isNull);
    expect(task.urgent, isNull);
    expect(jsonDecode(task.recurrence!), {
      'rule': 'FREQ=WEEKLY;BYDAY=MO',
      'until': '2026-12-31',
    });
    final mutation = await database
        .select(database.outboxMutations)
        .getSingle();
    final payload = jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
    expect(payload['important'], isNull);
    expect(payload['urgent'], isNull);
    expect(payload['recurrence'], {
      'rule': 'FREQ=WEEKLY;BYDAY=MO',
      'until': '2026-12-31',
    });
    expect(database.schemaVersion, 6);
  });

  test(
    'v5 fixture migrates legacy Task/Schedule data and creates Outbox',
    () async {
      final directory = await Directory.systemTemp.createTemp('orialis-v5-');
      final path = '${directory.path}/app.sqlite';
      final database = AppDatabase(
        executor: NativeDatabase(File(path), setup: createV5Fixture),
      );
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });

      final task = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('legacy-task'))).getSingle();
      final schedule = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals('legacy-schedule'))).getSingle();
      expect(database.schemaVersion, 6);
      expect(task.important, isNull);
      expect(task.urgent, true);
      expect(task.recurrence, contains('FREQ=DAILY'));
      expect(schedule.description, '说明');
      expect(schedule.location, '地点');
      expect(await database.select(database.outboxMutations).get(), isEmpty);
    },
  );

  test('outbox mutation survives closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('orialis-outbox-');
    final path = '${directory.path}/app.sqlite';
    final firstDatabase = openDatabase(path);
    final firstStore = OutboxStore(firstDatabase);
    final created = await firstStore.enqueue(
      entityType: 'task',
      entityId: 'task-1',
      operation: 'update',
      payloadJson: '{"title":"原始快照"}',
      baseVersion: 4,
      entityRevision: 2,
    );
    await firstDatabase.close();

    final reopened = openDatabase(path);
    addTearDown(() async {
      await reopened.close();
      await directory.delete(recursive: true);
    });
    final restored = await (reopened.select(
      reopened.outboxMutations,
    )..where((row) => row.mutationId.equals(created.mutationId))).getSingle();
    expect(restored.mutationId, created.mutationId);
    expect(restored.payloadJson, '{"title":"原始快照"}');
    expect(restored.baseVersion, 4);
    expect(restored.status, OutboxStatus.pending);
  });

  test(
    'pending mutations merge, but an in-flight mutation is immutable',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final store = OutboxStore(database);

      final first = await store.enqueue(
        entityType: 'task',
        entityId: 'task-1',
        operation: 'update',
        payloadJson: '{"title":"v1"}',
        baseVersion: 1,
        entityRevision: 1,
      );
      final merged = await store.enqueue(
        entityType: 'task',
        entityId: 'task-1',
        operation: 'update',
        payloadJson: '{"title":"v2"}',
        baseVersion: 1,
        entityRevision: 2,
      );
      expect(merged.mutationId, first.mutationId);
      expect(merged.payloadJson, '{"title":"v2"}');

      await store.markInFlight(first.mutationId);
      final next = await store.enqueue(
        entityType: 'task',
        entityId: 'task-1',
        operation: 'update',
        payloadJson: '{"title":"v3"}',
        baseVersion: 1,
        entityRevision: 3,
      );
      expect(next.mutationId, isNot(first.mutationId));

      final sent = await (database.select(
        database.outboxMutations,
      )..where((row) => row.mutationId.equals(first.mutationId))).getSingle();
      expect(sent.status, OutboxStatus.inFlight);
      expect(sent.payloadJson, '{"title":"v2"}');
    },
  );

  test(
    'recovering an interrupted retry reuses mutationId and payload',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final store = OutboxStore(database);
      final created = await store.enqueue(
        entityType: 'schedule',
        entityId: 'schedule-1',
        operation: 'create',
        payloadJson: '{"title":"演示"}',
        baseVersion: null,
        entityRevision: 0,
      );
      await store.markInFlight(created.mutationId);
      final inFlight = await (database.select(
        database.outboxMutations,
      )..where((row) => row.mutationId.equals(created.mutationId))).getSingle();
      expect(inFlight.attemptCount, 1);
      await store.recoverInFlight();
      await store.markInFlight(created.mutationId);
      final retry = await store.findPendingForEntity('schedule', 'schedule-1');
      expect(retry, isNull);
      final secondAttempt = await (database.select(
        database.outboxMutations,
      )..where((row) => row.mutationId.equals(created.mutationId))).getSingle();
      expect(secondAttempt.mutationId, created.mutationId);
      expect(secondAttempt.payloadJson, created.payloadJson);
      expect(secondAttempt.attemptCount, 2);
    },
  );

  test('schedule outbox snapshot retains every v1 field', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = EventRepository(database: database, config: AppConfig());

    await repository.createCalendarEvent(
      title: '物理实验课',
      description: '带护目镜',
      location: '实验楼 302',
      startAt: DateTime.utc(2026, 9, 18, 1),
      endAt: DateTime.utc(2026, 9, 18, 3),
      reminderMinutes: 30,
    );

    final mutation = await database
        .select(database.outboxMutations)
        .getSingle();
    final payload = jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
    expect(payload['title'], '物理实验课');
    expect(payload['description'], '带护目镜');
    expect(payload['location'], '实验楼 302');
    expect(payload['startAt'], '2026-09-18T01:00:00.000Z');
    expect(payload['endAt'], '2026-09-18T03:00:00.000Z');
    expect(payload['allDay'], false);
    expect(payload['reminderMinutes'], 30);
    expect(payload['deletedAt'], isNull);
  });

  test(
    'acknowledged mutation recovery closes the entity update crash window',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final store = OutboxStore(database);
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'task-recovery',
              title: '待恢复',
              createdAt: '2026-09-17T00:00:00.000Z',
              updatedAt: '2026-09-17T00:00:00.000Z',
              localRevision: const Value(1),
              syncStatus: const Value('pendingUpdate'),
            ),
          );
      final mutation = await store.enqueue(
        entityType: 'task',
        entityId: 'task-recovery',
        operation: 'update',
        payloadJson: '{"title":"待恢复"}',
        baseVersion: 2,
        entityRevision: 1,
      );
      await store.markInFlight(mutation.mutationId);
      // Simulate the legacy order: the process stopped after acknowledgement.
      await store.acknowledge(mutation.mutationId);

      var task = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('task-recovery'))).getSingle();
      expect(task.syncStatus, 'pendingUpdate');
      await store.recoverAcknowledgedEntities();

      task = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('task-recovery'))).getSingle();
      expect(task.syncStatus, 'synced');
      final restored =
          await (database.select(database.outboxMutations)
                ..where((row) => row.mutationId.equals(mutation.mutationId)))
              .getSingle();
      expect(restored.status, OutboxStatus.acknowledged);
    },
  );

  test(
    'failed entity/outbox transaction leaves no silent entity-only write',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);

      await expectLater(
        database.transaction(() async {
          await database
              .into(database.tasks)
              .insert(
                TasksCompanion.insert(
                  id: 'task-rollback',
                  title: '不会留下孤立实体',
                  createdAt: '2026-09-17T00:00:00.000Z',
                  updatedAt: '2026-09-17T00:00:00.000Z',
                  syncStatus: const Value('pendingCreate'),
                ),
              );
          // Represents an outbox enqueue failure in the same transaction.
          throw StateError('simulated outbox failure');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await database.select(database.tasks).get(), isEmpty);
      expect(await database.select(database.outboxMutations).get(), isEmpty);
    },
  );
}
