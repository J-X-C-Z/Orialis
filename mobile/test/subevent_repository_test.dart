import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/events/data/schedule_repository.dart';
import 'package:orialis_mobile/features/events/data/task_repository.dart';

void main() {
  late AppDatabase database;
  late EventRepository events;
  late TaskRepository tasks;
  late ScheduleRepository schedules;

  setUp(() {
    database = AppDatabase(executor: NativeDatabase.memory());
    events = EventRepository(database: database, config: AppConfig());
    tasks = TaskRepository(delegate: events);
    schedules = ScheduleRepository(delegate: events);
  });
  tearDown(() => database.close());

  test('task attachments validate and flow into the outbox payload', () async {
    await schedules.create(
      title: '安排',
      startAt: DateTime.utc(2026, 9, 24, 9),
      endAt: DateTime.utc(2026, 9, 24, 10),
      important: true,
    );
    final schedule = await database.select(database.calendarEvents).getSingle();
    expect(schedule.important, isTrue);
    var scheduleMutation = await (database.select(
      database.outboxMutations,
    )..where((row) => row.entityId.equals(schedule.id))).getSingle();
    expect(
      (jsonDecode(scheduleMutation.payloadJson)
          as Map<String, dynamic>)['important'],
      isTrue,
    );
    await schedules.update(
      schedule,
      title: schedule.title,
      startAt: DateTime.parse(schedule.startAt),
      endAt: DateTime.parse(schedule.endAt),
      important: false,
    );
    scheduleMutation = await (database.select(
      database.outboxMutations,
    )..where((row) => row.entityId.equals(schedule.id))).getSingle();
    expect(
      (jsonDecode(scheduleMutation.payloadJson)
          as Map<String, dynamic>)['important'],
      isFalse,
    );

    await tasks.create(title: '排期任务', scheduleId: schedule.id);
    final child = await database.select(database.tasks).getSingle();
    expect(child.scheduleId, schedule.id);
    final mutation = await (database.select(
      database.outboxMutations,
    )..where((row) => row.entityId.equals(child.id))).getSingle();
    final payload = jsonDecode(mutation.payloadJson) as Map<String, dynamic>;
    expect(payload['scheduleId'], schedule.id);
    expect(payload['parentTaskId'], isNull);
    await expectLater(
      tasks.create(title: '日程任务的子项', parentTaskId: child.id),
      throwsArgumentError,
    );

    await tasks.create(title: '已有子项的根任务');
    final rootWithChild = (await database.select(database.tasks).get())
        .firstWhere((task) => task.title == '已有子项的根任务');
    await tasks.create(title: '根任务的子项', parentTaskId: rootWithChild.id);
    await expectLater(
      tasks.updateDetails(
        rootWithChild,
        title: rootWithChild.title,
        scheduleId: schedule.id,
        scheduleIdProvided: true,
      ),
      throwsArgumentError,
    );

    await tasks.updateDetails(child, title: '已改名');
    var updated = await (database.select(
      database.tasks,
    )..where((row) => row.id.equals(child.id))).getSingle();
    expect(updated.scheduleId, schedule.id, reason: 'omitted preserves');
    await tasks.updateDetails(
      updated,
      title: '已解除排期',
      scheduleIdProvided: true,
    );
    updated = await (database.select(
      database.tasks,
    )..where((row) => row.id.equals(child.id))).getSingle();
    expect(updated.scheduleId, isNull, reason: 'explicit null clears');

    await expectLater(
      tasks.create(
        title: '非法双挂载',
        parentTaskId: child.id,
        scheduleId: schedule.id,
      ),
      throwsArgumentError,
    );
    await expectLater(
      tasks.create(title: '自引用', parentTaskId: 'self'),
      throwsArgumentError,
    );
    await expectLater(
      tasks.create(title: '缺失父项', parentTaskId: 'missing'),
      throwsArgumentError,
    );
    await expectLater(
      tasks.updateDetails(
        updated,
        title: updated.title,
        parentTaskId: updated.id,
        parentTaskIdProvided: true,
      ),
      throwsArgumentError,
    );
  });

  test(
    'parent completion cascades down; child completion recomputes parent',
    () async {
      await tasks.create(title: '父任务');
      final parent = await database.select(database.tasks).getSingle();
      await tasks.create(title: '子项 1', parentTaskId: parent.id);
      await tasks.create(title: '子项 2', parentTaskId: parent.id);
      final children = await tasks.watchChildren(parent.id).first;

      await tasks.complete(parent, true);
      var storedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      var storedChildren = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.equals(parent.id))).get();
      expect(storedParent.completed, isTrue);
      expect(storedChildren.every((task) => task.completed), isTrue);
      expect(
        storedChildren.every((task) => task.syncStatus == 'pendingCreate'),
        isTrue,
      );
      for (final child in storedChildren) {
        final createMutation = await (database.select(
          database.outboxMutations,
        )..where((row) => row.entityId.equals(child.id))).getSingle();
        expect(createMutation.operation, 'create');
        expect(
          (jsonDecode(createMutation.payloadJson)
              as Map<String, dynamic>)['completed'],
          isTrue,
        );
      }

      await tasks.complete(storedChildren.first, false);
      storedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      expect(storedParent.completed, isFalse);
      expect(
        (await (database.select(database.tasks)
                  ..where((row) => row.id.equals(storedChildren.last.id)))
                .getSingle())
            .completed,
        isTrue,
      );

      await tasks.complete(storedChildren.first, true);
      storedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      expect(storedParent.completed, isTrue, reason: 'all children complete');

      final freshParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      await tasks.complete(freshParent, false);
      expect(
        (await (database.select(
              database.tasks,
            )..where((row) => row.id.equals(children.last.id))).getSingle())
            .completed,
        isTrue,
        reason: 'reopening a parent does not undo child completion',
      );
      expect(await tasks.watchChildren(parent.id).first, hasLength(2));
    },
  );

  test(
    'task and schedule deletion soft-delete their direct tasks with outbox',
    () async {
      await tasks.create(title: '父任务');
      final parent = await database.select(database.tasks).getSingle();
      await tasks.create(title: '子任务', parentTaskId: parent.id);
      final child = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.equals(parent.id))).getSingle();
      await tasks.delete(parent);
      final deletedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      final deletedChild = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      expect(deletedParent.deletedAt, isNotNull);
      expect(deletedChild.deletedAt, isNotNull);

      await schedules.create(
        title: '日程',
        startAt: DateTime.utc(2026, 9, 25, 9),
        endAt: DateTime.utc(2026, 9, 25, 10),
      );
      final schedule = await database
          .select(database.calendarEvents)
          .getSingle();
      await tasks.create(title: '日程任务', scheduleId: schedule.id);
      final scheduleTask = await (database.select(
        database.tasks,
      )..where((row) => row.scheduleId.equals(schedule.id))).getSingle();
      await events.deleteCalendarEvent(schedule);
      final deletedScheduleTask = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(scheduleTask.id))).getSingle();
      expect(deletedScheduleTask.deletedAt, isNotNull);
      expect(
        await (database.select(database.outboxMutations)..where(
              (row) =>
                  row.entityType.equals('task') &
                  row.operation.equals('delete'),
            ))
            .get(),
        hasLength(3),
      );
    },
  );

  test(
    'stale editor save preserves lifecycle state and a new child reopens parent',
    () async {
      await tasks.create(title: '父任务');
      final staleParent = await database.select(database.tasks).getSingle();
      await tasks.create(title: '已完成的子项', parentTaskId: staleParent.id);
      final firstChild = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.equals(staleParent.id))).getSingle();
      await tasks.complete(firstChild, true);

      var currentParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(staleParent.id))).getSingle();
      expect(currentParent.completed, isTrue);
      await tasks.updateDetails(staleParent, title: '由旧编辑器保存');
      currentParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(staleParent.id))).getSingle();
      expect(currentParent.title, '由旧编辑器保存');
      expect(currentParent.completed, isTrue);
      final parentMutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(staleParent.id))).getSingle();
      expect(
        (jsonDecode(parentMutation.payloadJson)
            as Map<String, dynamic>)['completed'],
        isTrue,
      );

      await tasks.create(title: '新未完成子项', parentTaskId: staleParent.id);
      currentParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(staleParent.id))).getSingle();
      expect(currentParent.completed, isFalse);
      final newChild =
          await (database.select(database.tasks)..where(
                (row) =>
                    row.parentTaskId.equals(staleParent.id) &
                    row.completed.equals(false),
              ))
              .getSingle();
      expect(await tasks.watchChildren(staleParent.id).first, hasLength(2));

      await tasks.delete(newChild);
      currentParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(staleParent.id))).getSingle();
      expect(
        currentParent.completed,
        isFalse,
        reason:
            'deleting the final incomplete child does not vacuously complete its parent',
      );
      expect(await tasks.watchChildren(staleParent.id).first, hasLength(1));
    },
  );

  test(
    'attaching an incomplete existing task reopens a completed parent',
    () async {
      await tasks.create(title: '父任务');
      final parent = await database.select(database.tasks).getSingle();
      await tasks.complete(parent, true);
      await tasks.create(title: '待挂接任务');
      final unattached = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.isNull())).get();
      final child = unattached.firstWhere((task) => task.id != parent.id);

      await tasks.updateDetails(
        child,
        title: child.title,
        parentTaskId: parent.id,
        parentTaskIdProvided: true,
      );

      final reopenedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      expect(reopenedParent.completed, isFalse);
      final mutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(parent.id))).getSingle();
      expect(
        (jsonDecode(mutation.payloadJson) as Map<String, dynamic>)['completed'],
        isFalse,
      );
    },
  );

  test(
    'synced derived completion stays local; only the cause is queued',
    () async {
      await tasks.create(title: '父任务');
      final parent = await database.select(database.tasks).getSingle();
      await tasks.create(title: '子任务', parentTaskId: parent.id);
      final child = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.equals(parent.id))).getSingle();
      await database.delete(database.outboxMutations).go();
      await (database.update(database.tasks)).write(
        const TasksCompanion(
          version: Value(4),
          remoteVersion: Value(4),
          localRevision: Value(7),
          syncStatus: Value('synced'),
        ),
      );

      await tasks.complete(parent, true);
      var derivedChild = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      expect(derivedChild.completed, isTrue);
      expect(derivedChild.localRevision, 7);
      expect(derivedChild.syncStatus, 'synced');
      var mutations = await database.select(database.outboxMutations).get();
      expect(mutations, hasLength(1));
      expect(mutations.single.entityId, parent.id);

      await database.delete(database.outboxMutations).go();
      await (database.update(database.tasks)).write(
        const TasksCompanion(
          completed: Value(false),
          completedAt: Value(null),
          syncStatus: Value('synced'),
          localRevision: Value(12),
        ),
      );
      final childBefore = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      await tasks.complete(childBefore, true);
      final derivedParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      expect(derivedParent.completed, isTrue);
      expect(derivedParent.localRevision, 12);
      expect(derivedParent.syncStatus, 'synced');
      mutations = await database.select(database.outboxMutations).get();
      expect(mutations, hasLength(1));
      expect(mutations.single.entityId, child.id);
    },
  );

  test(
    'pending update marker survives later edits and direct completion clears it',
    () async {
      await tasks.create(title: '父任务');
      final parent = await database.select(database.tasks).getSingle();
      await tasks.create(title: '子任务', parentTaskId: parent.id);
      final child = await (database.select(
        database.tasks,
      )..where((row) => row.parentTaskId.equals(parent.id))).getSingle();
      await database.delete(database.outboxMutations).go();
      await (database.update(database.tasks)).write(
        const TasksCompanion(
          version: Value(3),
          remoteVersion: Value(3),
          syncStatus: Value('synced'),
        ),
      );
      final currentChild = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      await tasks.updateDetails(currentChild, title: '保留的本地编辑');
      final currentParent = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(parent.id))).getSingle();
      await tasks.complete(currentParent, true);

      var childMutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(child.id))).getSingle();
      var payload =
          jsonDecode(childMutation.payloadJson) as Map<String, dynamic>;
      expect(payload['_derivedCompletionCauseId'], parent.id);
      expect(payload['title'], '保留的本地编辑');
      expect(payload['completed'], isTrue);

      final editedChild = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      await tasks.updateDetails(editedChild, title: '后续标题编辑');
      childMutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(child.id))).getSingle();
      payload = jsonDecode(childMutation.payloadJson) as Map<String, dynamic>;
      expect(payload['_derivedCompletionCauseId'], parent.id);
      expect(payload['title'], '后续标题编辑');

      final latestChild = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(child.id))).getSingle();
      await tasks.complete(latestChild, false);
      childMutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(child.id))).getSingle();
      payload = jsonDecode(childMutation.payloadJson) as Map<String, dynamic>;
      expect(payload.containsKey('_derivedCompletionCauseId'), isFalse);
      final parentMutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals(parent.id))).getSingle();
      final parentPayload =
          jsonDecode(parentMutation.payloadJson) as Map<String, dynamic>;
      expect(parentPayload['_derivedCompletionCauseId'], child.id);
      expect(parentPayload['completed'], isFalse);
    },
  );
}
