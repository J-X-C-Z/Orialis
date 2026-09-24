import '../../../core/database/app_database.dart';
import 'event_repository.dart';

/// Schedule-focused boundary. CalendarEvents remains the storage-compatible
/// representation and EventRepository remains the compatibility facade.
class ScheduleRepository {
  ScheduleRepository({required EventRepository delegate})
    : _delegate = delegate;

  final EventRepository _delegate;

  Stream<List<CalendarEvent>> watchAll() => _delegate.watchCalendarEvents();

  Stream<List<CalendarEvent>> watchForDate(DateTime date) =>
      _delegate.watchCalendarEventsForDate(date);

  Future<void> create({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool allDay = false,
    bool important = false,
    int? reminderMinutes,
  }) => _delegate.createCalendarEvent(
    title: title,
    startAt: startAt,
    endAt: endAt,
    description: description,
    location: location,
    allDay: allDay,
    important: important,
    reminderMinutes: reminderMinutes,
  );

  Future<void> update(
    CalendarEvent schedule, {
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool? allDay,
    bool? important,
    int? reminderMinutes,
  }) => _delegate.updateSchedule(
    schedule,
    title: title,
    startAt: startAt,
    endAt: endAt,
    description: description,
    location: location,
    allDay: allDay,
    important: important,
    reminderMinutes: reminderMinutes,
    reminderMinutesProvided: true,
  );

  Future<void> delete(CalendarEvent schedule) =>
      _delegate.deleteCalendarEvent(schedule);
}
