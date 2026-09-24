import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/outbox_store.dart';

class TaskRecurrence {
  const TaskRecurrence({required this.rule, required this.until});

  final String rule;
  final String until;

  Map<String, String> toJson() => {'rule': rule, 'until': until};

  String encode() {
    if (!RegExp(r'^(?:RRULE:)?FREQ=[A-Z]+(?:;.*)?$').hasMatch(rule) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(until)) {
      throw ArgumentError(
        'recurrence must contain an RRULE and YYYY-MM-DD until',
      );
    }
    return jsonEncode(toJson());
  }

  static TaskRecurrence? decode(String? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map ||
        decoded['rule'] is! String ||
        decoded['until'] is! String) {
      throw const FormatException('invalid recurrence');
    }
    return TaskRecurrence(
      rule: decoded['rule'] as String,
      until: decoded['until'] as String,
    );
  }
}

class EventRepository {
  EventRepository({required this.database, required this.config});

  final AppDatabase database;
  final AppConfig config;

  Stream<List<Task>> watchTasks() => database.watchActiveTasks();

  Stream<List<Task>> watchChildren(String parentTaskId) =>
      (database.select(database.tasks)
            ..where(
              (row) =>
                  row.deletedAt.isNull() &
                  row.parentTaskId.equals(parentTaskId),
            )
            ..orderBy([(row) => OrderingTerm(expression: row.due)]))
          .watch();

  Stream<List<Task>> watchTasksForSchedule(String scheduleId) =>
      (database.select(database.tasks)
            ..where(
              (row) =>
                  row.deletedAt.isNull() & row.scheduleId.equals(scheduleId),
            )
            ..orderBy([(row) => OrderingTerm(expression: row.due)]))
          .watch();

  Stream<List<Task>> watchForSchedule(String scheduleId) =>
      watchTasksForSchedule(scheduleId);

  Stream<List<CalendarEvent>> watchCalendarEvents() =>
      database.watchActiveCalendarEvents();

  Stream<List<Task>> watchTodayTasks(DateTime date) {
    final key = _dateKey(date);
    return (database.select(database.tasks)
          ..where((row) => row.deletedAt.isNull() & row.due.equals(key))
          ..orderBy([(row) => OrderingTerm(expression: row.dueTime)]))
        .watch();
  }

  /// Tasks are queried independently from schedules. `date` matches the
  /// task's calendar-day due key; tasks never participate in schedule queries.
  Stream<List<Task>> watchTasksForDate(DateTime date) => watchTodayTasks(date);

  Stream<List<Task>> watchTasksByFilters({
    DateTime? dueOn,
    DateTime? dueBefore,
    bool? important,
    bool? urgent,
    bool? completed,
  }) {
    final query = database.select(database.tasks)
      ..where((row) {
        Expression<bool> predicate = row.deletedAt.isNull();
        if (dueOn != null) {
          predicate = predicate & row.due.equals(_dateKey(dueOn));
        }
        if (dueBefore != null) {
          predicate =
              predicate & row.due.isSmallerOrEqualValue(_dateKey(dueBefore));
        }
        if (important != null) {
          predicate = predicate & row.important.equals(important);
        }
        if (urgent != null) {
          predicate = predicate & row.urgent.equals(urgent);
        }
        if (completed != null) {
          predicate = predicate & row.completed.equals(completed);
        }
        return predicate;
      })
      ..orderBy([
        (row) => OrderingTerm(expression: row.due),
        (row) => OrderingTerm(expression: row.dueTime),
      ]);
    return query.watch();
  }

  Stream<List<CalendarEvent>> watchCalendarEventsForDate(DateTime date) {
    final start = DateTime(date.year, date.month, date.day).toUtc();
    final end = start.add(const Duration(days: 1));
    return (database.select(database.calendarEvents)
          ..where(
            (row) =>
                row.deletedAt.isNull() &
                row.startAt.isSmallerThanValue(end.toIso8601String()) &
                row.endAt.isBiggerThanValue(start.toIso8601String()),
          )
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .watch();
  }

  Future<void> createTask({
    required String title,
    String? notes,
    String? due,
    String? dueTime,
    bool? important,
    bool? urgent,
    int? reminderMinutes,
    TaskRecurrence? recurrence,
    String? projectId,
    String? parentTaskId,
    String? scheduleId,
  }) async {
    _validateDueTime(due, dueTime);
    _validateAttachmentExclusive(parentTaskId, scheduleId);
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v7();
    await database.transaction(() async {
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: id,
              title: title.trim(),
              notes: Value(
                notes?.trim().isEmpty == true ? null : notes?.trim(),
              ),
              due: Value(due),
              dueTime: Value(dueTime),
              important: Value(important),
              urgent: Value(urgent),
              reminderMinutes: Value(reminderMinutes),
              recurrence: Value(recurrence?.encode()),
              projectId: Value(projectId),
              parentTaskId: Value(parentTaskId),
              scheduleId: Value(scheduleId),
              createdAt: timestamp,
              updatedAt: timestamp,
              syncStatus: const Value('pendingCreate'),
            ),
          );
      await _validateTaskAttachmentInTransaction(
        id: id,
        parentTaskId: parentTaskId,
        scheduleId: scheduleId,
      );
      if (parentTaskId != null) {
        await _reopenParentForIncompleteChildInTransaction(
          parentTaskId,
          causeTaskId: id,
        );
      }
      await _enqueueTaskInTransaction(id);
    });
  }

  Future<void> createCalendarEvent({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool allDay = false,
    bool important = false,
    int? reminderMinutes,
  }) async {
    _validateSchedule(startAt, endAt, reminderMinutes);
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v7();
    await database.transaction(() async {
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: id,
              title: title.trim(),
              description: Value(
                description?.trim().isEmpty == true
                    ? null
                    : description?.trim(),
              ),
              location: Value(
                location?.trim().isEmpty == true ? null : location?.trim(),
              ),
              startAt: startAt.toUtc().toIso8601String(),
              endAt: endAt.toUtc().toIso8601String(),
              allDay: Value(allDay),
              important: Value(important),
              reminderMinutes: Value(reminderMinutes),
              createdAt: timestamp,
              updatedAt: timestamp,
              syncStatus: const Value('pendingCreate'),
            ),
          );
      await _enqueueScheduleInTransaction(id);
    });
  }

  /// Parent completion propagates to direct children. Child completion marks
  /// the parent complete only after every active child is complete; reopening
  /// a parent leaves child completion unchanged.
  Future<void> completeTask(Task task, bool completed) async {
    await database.transaction(() async {
      final current = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).getSingle();
      await _setTaskCompletionInTransaction(current, completed);
      if (current.parentTaskId == null && completed) {
        final children =
            await (database.select(database.tasks)..where(
                  (row) =>
                      row.parentTaskId.equals(current.id) &
                      row.deletedAt.isNull(),
                ))
                .get();
        for (final child in children) {
          await _setDerivedTaskCompletionInTransaction(
            child,
            true,
            causeTaskId: current.id,
          );
        }
      } else if (current.parentTaskId != null) {
        final parent =
            await (database.select(database.tasks)
                  ..where((row) => row.id.equals(current.parentTaskId!)))
                .getSingleOrNull();
        if (parent != null && parent.deletedAt == null) {
          if (!completed) {
            await _setDerivedTaskCompletionInTransaction(
              parent,
              false,
              causeTaskId: current.id,
            );
          } else {
            final siblings =
                await (database.select(database.tasks)..where(
                      (row) =>
                          row.parentTaskId.equals(parent.id) &
                          row.deletedAt.isNull(),
                    ))
                    .get();
            if (siblings.isNotEmpty &&
                siblings.every((child) => child.completed)) {
              await _setDerivedTaskCompletionInTransaction(
                parent,
                true,
                causeTaskId: current.id,
              );
            }
          }
        }
      }
    });
  }

  Future<void> updateTask(Task task, {required String title}) async {
    await database.transaction(() async {
      final current = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).getSingle();
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).write(
        TasksCompanion(
          title: Value(title.trim()),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(current.localRevision + 1),
          remoteVersion: Value(current.remoteVersion),
          syncStatus: Value(_statusAfterLocalEdit(current.syncStatus)),
        ),
      );
      await _enqueueTaskInTransaction(task.id);
    });
  }

  Future<void> updateTaskDetails(
    Task task, {
    required String title,
    String? notes,
    String? due,
    String? dueTime,
    bool? important,
    bool? urgent,
    int? reminderMinutes,
    TaskRecurrence? recurrence,
    String? projectId,
    String? parentTaskId,
    String? scheduleId,
    bool reminderMinutesProvided = false,
    bool recurrenceProvided = false,
    bool projectIdProvided = false,
    bool parentTaskIdProvided = false,
    bool scheduleIdProvided = false,
  }) async {
    _validateDueTime(due, dueTime);
    await database.transaction(() async {
      final current = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).getSingle();
      final nextParentTaskId = parentTaskIdProvided
          ? parentTaskId
          : current.parentTaskId;
      final nextScheduleId = scheduleIdProvided
          ? scheduleId
          : current.scheduleId;
      _validateAttachmentExclusive(nextParentTaskId, nextScheduleId);
      await _validateTaskAttachmentInTransaction(
        id: task.id,
        parentTaskId: nextParentTaskId,
        scheduleId: nextScheduleId,
      );
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).write(
        TasksCompanion(
          title: Value(title.trim()),
          notes: Value(notes?.trim().isEmpty == true ? null : notes?.trim()),
          due: Value(due),
          dueTime: Value(dueTime),
          important: Value(important),
          urgent: Value(urgent),
          reminderMinutes: reminderMinutesProvided
              ? Value(reminderMinutes)
              : const Value.absent(),
          recurrence: recurrenceProvided
              ? Value(recurrence?.encode())
              : const Value.absent(),
          projectId: projectIdProvided
              ? Value(projectId)
              : const Value.absent(),
          parentTaskId: parentTaskIdProvided
              ? Value(parentTaskId)
              : const Value.absent(),
          scheduleId: scheduleIdProvided
              ? Value(scheduleId)
              : const Value.absent(),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(current.localRevision + 1),
          remoteVersion: Value(current.remoteVersion),
          syncStatus: Value(_statusAfterLocalEdit(current.syncStatus)),
        ),
      );
      if (nextParentTaskId != null && !current.completed) {
        await _reopenParentForIncompleteChildInTransaction(
          nextParentTaskId,
          causeTaskId: task.id,
        );
      }
      await _enqueueTaskInTransaction(task.id);
    });
  }

  Future<void> updateSchedule(
    CalendarEvent schedule, {
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool? allDay,
    bool? important,
    int? reminderMinutes,
    bool reminderMinutesProvided = false,
  }) async {
    _validateSchedule(startAt, endAt, reminderMinutes);
    await database.transaction(() async {
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(schedule.id))).write(
        CalendarEventsCompanion(
          title: Value(title.trim()),
          description: Value(
            description?.trim().isEmpty == true ? null : description?.trim(),
          ),
          location: Value(
            location?.trim().isEmpty == true ? null : location?.trim(),
          ),
          startAt: Value(startAt.toUtc().toIso8601String()),
          endAt: Value(endAt.toUtc().toIso8601String()),
          allDay: allDay == null ? const Value.absent() : Value(allDay),
          important: important == null
              ? const Value.absent()
              : Value(important),
          reminderMinutes: reminderMinutesProvided
              ? Value(reminderMinutes)
              : const Value.absent(),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(schedule.localRevision + 1),
          remoteVersion: Value(schedule.remoteVersion),
          syncStatus: Value(_statusAfterLocalEdit(schedule.syncStatus)),
        ),
      );
      await _enqueueScheduleInTransaction(schedule.id);
    });
  }

  Future<void> deleteSchedule(CalendarEvent schedule) =>
      deleteCalendarEvent(schedule);

  /// Soft-deletes the task and any active direct children atomically.
  Future<void> deleteTask(Task task) async {
    await database.transaction(() async {
      final current = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).getSingle();
      final children =
          await (database.select(database.tasks)..where(
                (row) =>
                    row.parentTaskId.equals(task.id) & row.deletedAt.isNull(),
              ))
              .get();
      for (final child in children) {
        await _softDeleteTaskInTransaction(child);
      }
      await _softDeleteTaskInTransaction(current);
    });
  }

  /// Soft-deletes a schedule and its directly attached tasks atomically.
  Future<void> deleteCalendarEvent(CalendarEvent event) async {
    await database.transaction(() async {
      final current = await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals(event.id))).getSingleOrNull();
      if (current == null || current.deletedAt != null) return;
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(event.id))).write(
        CalendarEventsCompanion(
          deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(current.localRevision + 1),
          remoteVersion: Value(current.remoteVersion),
          syncStatus: const Value('pendingDelete'),
        ),
      );
      final children =
          await (database.select(database.tasks)..where(
                (row) =>
                    row.scheduleId.equals(event.id) & row.deletedAt.isNull(),
              ))
              .get();
      for (final child in children) {
        final grandchildren =
            await (database.select(database.tasks)..where(
                  (row) =>
                      row.parentTaskId.equals(child.id) &
                      row.deletedAt.isNull(),
                ))
                .get();
        for (final grandchild in grandchildren) {
          await _softDeleteTaskInTransaction(grandchild);
        }
        await _softDeleteTaskInTransaction(child);
      }
      await _enqueueScheduleInTransaction(event.id);
    });
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _statusAfterLocalEdit(String current) =>
      current == 'pendingCreate' ? 'pendingCreate' : 'pendingUpdate';

  Future<void> _setTaskCompletionInTransaction(
    Task task,
    bool completed,
  ) async {
    if (task.completed == completed) return;
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        completed: Value(completed),
        completedAt: const Value(null),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(task.localRevision + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: Value(_statusAfterLocalEdit(task.syncStatus)),
      ),
    );
    await _enqueueTaskInTransaction(
      task.id,
      clearDerivedCompletionMarker: true,
    );
  }

  Future<void> _softDeleteTaskInTransaction(Task task) async {
    if (task.deletedAt != null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        localRevision: Value(task.localRevision + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: const Value('pendingDelete'),
      ),
    );
    await _enqueueTaskInTransaction(task.id);
  }

  Future<void> _reopenParentForIncompleteChildInTransaction(
    String parentTaskId, {
    required String causeTaskId,
  }) async {
    final parent =
        await (database.select(database.tasks)..where(
              (row) => row.id.equals(parentTaskId) & row.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (parent != null && parent.completed) {
      await _setDerivedTaskCompletionInTransaction(
        parent,
        false,
        causeTaskId: causeTaskId,
      );
    }
  }

  Future<void> _setDerivedTaskCompletionInTransaction(
    Task task,
    bool completed, {
    required String causeTaskId,
  }) async {
    if (task.completed == completed || task.deletedAt != null) return;
    final pendingCreate = task.syncStatus == 'pendingCreate';
    final pendingUpdate = task.syncStatus == 'pendingUpdate';
    if (!pendingCreate && !pendingUpdate && task.syncStatus != 'synced') return;
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        completed: Value(completed),
        completedAt: const Value(null),
        updatedAt: pendingCreate || pendingUpdate
            ? Value(DateTime.now().toUtc().toIso8601String())
            : const Value.absent(),
        localRevision: pendingCreate || pendingUpdate
            ? Value(task.localRevision + 1)
            : const Value.absent(),
      ),
    );
    if (pendingCreate || pendingUpdate) {
      await _enqueueTaskInTransaction(
        task.id,
        derivedCompletionCauseId: pendingUpdate ? causeTaskId : null,
      );
    }
  }

  void _validateAttachmentExclusive(String? parentTaskId, String? scheduleId) {
    if (parentTaskId != null && scheduleId != null) {
      throw ArgumentError('a task cannot have both a parent task and schedule');
    }
  }

  Future<void> _validateTaskAttachmentInTransaction({
    required String id,
    required String? parentTaskId,
    required String? scheduleId,
  }) async {
    _validateAttachmentExclusive(parentTaskId, scheduleId);
    if (parentTaskId == id) {
      throw ArgumentError('a task cannot be its own parent');
    }
    if (parentTaskId != null) {
      final parent =
          await (database.select(database.tasks)..where(
                (row) => row.id.equals(parentTaskId) & row.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (parent == null) {
        throw ArgumentError('parent task does not exist');
      }
      if (parent.parentTaskId != null || parent.scheduleId != null) {
        throw ArgumentError('nested child tasks are not supported');
      }
      final existingChildren =
          await (database.select(database.tasks)..where(
                (row) => row.parentTaskId.equals(id) & row.deletedAt.isNull(),
              ))
              .get();
      if (existingChildren.isNotEmpty) {
        throw ArgumentError('a task with children cannot become a child');
      }
    }
    if (scheduleId != null) {
      final existingChildren =
          await (database.select(database.tasks)..where(
                (row) => row.parentTaskId.equals(id) & row.deletedAt.isNull(),
              ))
              .get();
      if (existingChildren.isNotEmpty) {
        throw ArgumentError('a task with children cannot attach to a schedule');
      }
      final schedule =
          await (database.select(database.calendarEvents)..where(
                (row) => row.id.equals(scheduleId) & row.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (schedule == null) {
        throw ArgumentError('schedule does not exist');
      }
    }
  }

  void _validateDueTime(String? due, String? dueTime) {
    if (due == null && dueTime != null) {
      throw ArgumentError('dueTime requires due');
    }
  }

  void _validateSchedule(
    DateTime startAt,
    DateTime endAt,
    int? reminderMinutes,
  ) {
    if (!startAt.isBefore(endAt)) {
      throw ArgumentError('schedule startAt must be before endAt');
    }
    if (reminderMinutes != null && reminderMinutes < 0) {
      throw ArgumentError('reminderMinutes cannot be negative');
    }
  }

  Future<void> _enqueueTaskInTransaction(
    String id, {
    String? derivedCompletionCauseId,
    bool clearDerivedCompletionMarker = false,
  }) async {
    final task = await (database.select(
      database.tasks,
    )..where((row) => row.id.equals(id))).getSingle();
    String? preservedCauseId;
    if (derivedCompletionCauseId == null && !clearDerivedCompletionMarker) {
      final mutations =
          await (database.select(database.outboxMutations)
                ..where(
                  (row) =>
                      row.entityType.equals('task') &
                      row.entityId.equals(id) &
                      row.status.isIn(const ['pending', 'inFlight']),
                )
                ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]))
              .get();
      for (final mutation in mutations) {
        final payload = jsonDecode(mutation.payloadJson);
        if (payload is Map && payload['_derivedCompletionCauseId'] is String) {
          preservedCauseId = payload['_derivedCompletionCauseId'] as String;
          break;
        }
      }
    }
    final payload = _taskPayload(task);
    final causeId = derivedCompletionCauseId ?? preservedCauseId;
    if (causeId != null) payload['_derivedCompletionCauseId'] = causeId;
    await OutboxStore(database).enqueue(
      entityType: 'task',
      entityId: task.id,
      operation: _operationFor(task.syncStatus),
      payloadJson: jsonEncode(payload),
      baseVersion:
          task.syncStatus == 'pendingUpdate' ||
              task.syncStatus == 'pendingDelete'
          ? task.remoteVersion
          : null,
      entityRevision: task.localRevision,
    );
  }

  Future<void> _enqueueScheduleInTransaction(String id) async {
    final event = await (database.select(
      database.calendarEvents,
    )..where((row) => row.id.equals(id))).getSingle();
    await OutboxStore(database).enqueue(
      entityType: 'schedule',
      entityId: event.id,
      operation: _operationFor(event.syncStatus),
      payloadJson: jsonEncode(_schedulePayload(event)),
      baseVersion:
          event.syncStatus == 'pendingUpdate' ||
              event.syncStatus == 'pendingDelete'
          ? event.remoteVersion
          : null,
      entityRevision: event.localRevision,
    );
  }

  String _operationFor(String status) => switch (status) {
    'pendingCreate' => 'create',
    'pendingDelete' => 'delete',
    _ => 'update',
  };

  Map<String, dynamic> _taskPayload(Task task) => {
    'id': task.id,
    'title': task.title,
    'notes': task.notes,
    'important': task.important,
    'urgent': task.urgent,
    'completed': task.completed,
    'completedAt': task.completedAt,
    'due': task.due,
    'dueTime': task.dueTime,
    'reminderMinutes': task.reminderMinutes,
    'projectId': task.projectId,
    'parentTaskId': task.parentTaskId,
    'scheduleId': task.scheduleId,
    'recurrence': task.recurrence == null ? null : jsonDecode(task.recurrence!),
    'createdAt': task.createdAt,
    'updatedAt': task.updatedAt,
    'deletedAt': task.deletedAt,
    'version': task.version,
  };

  Map<String, dynamic> _schedulePayload(CalendarEvent event) => {
    'id': event.id,
    'title': event.title,
    'description': event.description,
    'location': event.location,
    'startAt': event.startAt,
    'endAt': event.endAt,
    'allDay': event.allDay,
    'important': event.important,
    'reminderMinutes': event.reminderMinutes,
    'createdAt': event.createdAt,
    'updatedAt': event.updatedAt,
    'deletedAt': event.deletedAt,
    'version': event.version,
  };
}
