import '../../../core/database/app_database.dart';
import 'event_repository.dart';

/// Task-focused boundary. EventRepository remains the compatibility facade
/// until all callers migrate, so this slice does not change the public API.
class TaskRepository {
  TaskRepository({required EventRepository delegate}) : _delegate = delegate;

  final EventRepository _delegate;

  Stream<List<Task>> watchTasks() => _delegate.watchTasks();

  Stream<List<Task>> watchTasksForDate(DateTime date) =>
      _delegate.watchTasksForDate(date);

  Stream<List<Task>> watchTasksByFilters({
    DateTime? dueOn,
    DateTime? dueBefore,
    bool? important,
    bool? urgent,
    bool? completed,
  }) => _delegate.watchTasksByFilters(
    dueOn: dueOn,
    dueBefore: dueBefore,
    important: important,
    urgent: urgent,
    completed: completed,
  );

  Future<void> create({
    required String title,
    String? notes,
    String? due,
    String? dueTime,
    bool? important,
    bool? urgent,
    int? reminderMinutes,
    TaskRecurrence? recurrence,
    String? projectId,
  }) => _delegate.createTask(
    title: title,
    notes: notes,
    due: due,
    dueTime: dueTime,
    important: important,
    urgent: urgent,
    reminderMinutes: reminderMinutes,
    recurrence: recurrence,
    projectId: projectId,
  );

  Future<void> complete(Task task, bool completed) =>
      _delegate.completeTask(task, completed);

  Future<void> update(Task task, {required String title}) =>
      _delegate.updateTask(task, title: title);

  Future<void> updateDetails(
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
    bool reminderMinutesProvided = false,
    bool recurrenceProvided = false,
    bool projectIdProvided = false,
  }) => _delegate.updateTaskDetails(
    task,
    title: title,
    notes: notes,
    due: due,
    dueTime: dueTime,
    important: important,
    urgent: urgent,
    reminderMinutes: reminderMinutes,
    recurrence: recurrence,
    projectId: projectId,
    reminderMinutesProvided: reminderMinutesProvided,
    recurrenceProvided: recurrenceProvided,
    projectIdProvided: projectIdProvided,
  );

  Future<void> delete(Task task) => _delegate.deleteTask(task);
}
