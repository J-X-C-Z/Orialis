import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';

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
    bool important = false,
    bool urgent = false,
  }) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: const Uuid().v7(),
            title: title.trim(),
            notes: Value(notes?.trim().isEmpty == true ? null : notes?.trim()),
            due: Value(due),
            dueTime: Value(dueTime),
            important: Value(important),
            urgent: Value(urgent),
            createdAt: timestamp,
            updatedAt: timestamp,
            syncStatus: const Value('pendingCreate'),
          ),
        );
  }

  Future<void> createCalendarEvent({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool allDay = false,
  }) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: const Uuid().v7(),
            title: title.trim(),
            description: Value(
              description?.trim().isEmpty == true ? null : description?.trim(),
            ),
            location: Value(
              location?.trim().isEmpty == true ? null : location?.trim(),
            ),
            startAt: startAt.toUtc().toIso8601String(),
            endAt: endAt.toUtc().toIso8601String(),
            allDay: Value(allDay),
            createdAt: timestamp,
            updatedAt: timestamp,
            syncStatus: const Value('pendingCreate'),
          ),
        );
  }

  Future<void> completeTask(Task task, bool completed) async {
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        completed: Value(completed),
        completedAt: Value(
          completed ? DateTime.now().toUtc().toIso8601String() : null,
        ),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(task.version + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
  }

  Future<void> updateTask(Task task, {required String title}) async {
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        title: Value(title.trim()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(task.version + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
  }

  Future<void> updateTaskDetails(
    Task task, {
    required String title,
    String? notes,
    String? due,
    String? dueTime,
    bool? important,
    bool? urgent,
  }) async {
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        title: Value(title.trim()),
        notes: Value(notes?.trim().isEmpty == true ? null : notes?.trim()),
        due: Value(due),
        dueTime: Value(dueTime),
        important: important == null ? const Value.absent() : Value(important),
        urgent: urgent == null ? const Value.absent() : Value(urgent),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(task.version + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
  }

  Future<void> updateSchedule(
    CalendarEvent schedule, {
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool? allDay,
  }) async {
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
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(schedule.version + 1),
        remoteVersion: Value(schedule.remoteVersion),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
  }

  Future<void> deleteSchedule(CalendarEvent schedule) =>
      deleteCalendarEvent(schedule);

  Future<void> deleteTask(Task task) async {
    await (database.update(
      database.tasks,
    )..where((row) => row.id.equals(task.id))).write(
      TasksCompanion(
        deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(task.version + 1),
        remoteVersion: Value(task.remoteVersion),
        syncStatus: const Value('pendingDelete'),
      ),
    );
  }

  Future<void> deleteCalendarEvent(CalendarEvent event) async {
    await (database.update(
      database.calendarEvents,
    )..where((row) => row.id.equals(event.id))).write(
      CalendarEventsCompanion(
        deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        version: Value(event.version + 1),
        remoteVersion: Value(event.remoteVersion),
        syncStatus: const Value('pendingDelete'),
      ),
    );
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
