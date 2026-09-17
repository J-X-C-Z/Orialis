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
  }) async {
    _validateDueTime(due, dueTime);
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
              createdAt: timestamp,
              updatedAt: timestamp,
              syncStatus: const Value('pendingCreate'),
            ),
          );
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
    int? reminderMinutes,
  }) async {
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
              reminderMinutes: Value(reminderMinutes),
              createdAt: timestamp,
              updatedAt: timestamp,
              syncStatus: const Value('pendingCreate'),
            ),
          );
      await _enqueueScheduleInTransaction(id);
    });
  }

  Future<void> completeTask(Task task, bool completed) async {
    await database.transaction(() async {
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
      await _enqueueTaskInTransaction(task.id);
    });
  }

  Future<void> updateTask(Task task, {required String title}) async {
    await database.transaction(() async {
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).write(
        TasksCompanion(
          title: Value(title.trim()),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(task.localRevision + 1),
          remoteVersion: Value(task.remoteVersion),
          syncStatus: Value(_statusAfterLocalEdit(task.syncStatus)),
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
    bool reminderMinutesProvided = false,
    bool recurrenceProvided = false,
  }) async {
    _validateDueTime(due, dueTime);
    await database.transaction(() async {
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
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(task.localRevision + 1),
          remoteVersion: Value(task.remoteVersion),
          syncStatus: Value(_statusAfterLocalEdit(task.syncStatus)),
        ),
      );
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
    int? reminderMinutes,
    bool reminderMinutesProvided = false,
  }) async {
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

  Future<void> deleteTask(Task task) async {
    await database.transaction(() async {
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(task.id))).write(
        TasksCompanion(
          deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(task.localRevision + 1),
          remoteVersion: Value(task.remoteVersion),
          syncStatus: const Value('pendingDelete'),
        ),
      );
      await _enqueueTaskInTransaction(task.id);
    });
  }

  Future<void> deleteCalendarEvent(CalendarEvent event) async {
    await database.transaction(() async {
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(event.id))).write(
        CalendarEventsCompanion(
          deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          localRevision: Value(event.localRevision + 1),
          remoteVersion: Value(event.remoteVersion),
          syncStatus: const Value('pendingDelete'),
        ),
      );
      await _enqueueScheduleInTransaction(event.id);
    });
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _statusAfterLocalEdit(String current) =>
      current == 'pendingCreate' ? 'pendingCreate' : 'pendingUpdate';

  void _validateDueTime(String? due, String? dueTime) {
    if (due == null && dueTime != null) {
      throw ArgumentError('dueTime requires due');
    }
  }

  Future<void> _enqueueTaskInTransaction(String id) async {
    final task = await (database.select(
      database.tasks,
    )..where((row) => row.id.equals(id))).getSingle();
    await OutboxStore(database).enqueue(
      entityType: 'task',
      entityId: task.id,
      operation: _operationFor(task.syncStatus),
      payloadJson: jsonEncode(_taskPayload(task)),
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
    'reminderMinutes': event.reminderMinutes,
    'createdAt': event.createdAt,
    'updatedAt': event.updatedAt,
    'deletedAt': event.deletedAt,
    'version': event.version,
  };
}
