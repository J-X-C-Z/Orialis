import '../../core/database/app_database.dart';

String systemDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Task deadlines are wall-clock dates, unlike ISO Schedule instants.
DateTime? taskDeadline(Task task) {
  final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(task.due ?? '');
  final time = RegExp(
    r'^(\d{2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(task.dueTime ?? '');
  if (date == null || time == null) return null;
  final year = int.parse(date[1]!);
  final month = int.parse(date[2]!);
  final day = int.parse(date[3]!);
  final hour = int.parse(time[1]!);
  final minute = int.parse(time[2]!);
  final second = int.parse(time[3] ?? '0');
  final result = DateTime(year, month, day, hour, minute, second);
  if (result.year != year ||
      result.month != month ||
      result.day != day ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  return result;
}

String taskSystemRoute(String id) => '/events';
String scheduleSystemRoute(String id, DateTime date) =>
    '/calendar/schedule/${Uri.encodeComponent(id)}?date=${systemDate(date.toLocal())}';

Map<String, Object?> buildSystemSnapshot({
  required String scope,
  required List<Task> tasks,
  required List<CalendarEvent> events,
  required DateTime now,
}) {
  // Keep unchanged, recently fired rows for 24 hours so a Flutter refresh
  // does not cancel their visible notifications on resume. Native schedules
  // only future rows; completion, deletion and edits still remove/change rows.
  final reminderCutoff = now.subtract(const Duration(hours: 24));
  final today = systemDate(now.toLocal());
  final reminders = <Map<String, Object?>>[];
  final lines = <({DateTime time, String key, String text})>[];
  for (final task in tasks) {
    if (task.deletedAt != null || task.completed) continue;
    final deadline = taskDeadline(task);
    final minutes = task.reminderMinutes;
    if (deadline != null && minutes != null && minutes >= 0) {
      final fire = deadline.subtract(Duration(minutes: minutes));
      if (!fire.isBefore(reminderCutoff)) {
        reminders.add({
          'key': 'task:${task.id}',
          'title': task.title,
          'body': '任务提醒',
          'fireAtMillis': fire.millisecondsSinceEpoch,
          'route': taskSystemRoute(task.id),
          'kind': 'task',
          'due': task.due,
          'dueTime': task.dueTime,
          'reminderMinutes': minutes,
        });
      }
    }
    if (task.due == today) {
      lines.add((
        time: deadline ?? DateTime(now.year, now.month, now.day, 23, 59),
        key: 'task:${task.id}',
        text: '${task.dueTime ?? '今日'} ${task.title}',
      ));
    }
  }
  for (final event in events) {
    if (event.deletedAt != null) continue;
    final start = DateTime.tryParse(event.startAt);
    if (start == null) continue;
    final local = start.toLocal();
    final minutes = event.reminderMinutes;
    if (minutes != null && minutes >= 0) {
      final fire = start.subtract(Duration(minutes: minutes));
      if (!fire.isBefore(reminderCutoff)) {
        reminders.add({
          'key': 'schedule:${event.id}',
          'title': event.title,
          'body': event.location?.isNotEmpty == true ? event.location : '日程提醒',
          'fireAtMillis': fire.millisecondsSinceEpoch,
          'route': scheduleSystemRoute(event.id, local),
          'kind': 'schedule',
          'startsAtMillis': start.millisecondsSinceEpoch,
          'endsAtMillis': DateTime.tryParse(
            event.endAt,
          )?.millisecondsSinceEpoch,
          'important': event.important,
          'allDay': event.allDay,
        });
      }
    }
    if (systemDate(local) == today) {
      final label = event.allDay
          ? '全天'
          : '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
      lines.add((
        time: local,
        key: 'schedule:${event.id}',
        text: '$label ${event.title}',
      ));
    }
  }
  reminders.sort((a, b) {
    final time = (a['fireAtMillis'] as int).compareTo(b['fireAtMillis'] as int);
    return time != 0
        ? time
        : (a['key'] as String).compareTo(b['key'] as String);
  });
  lines.sort((a, b) {
    final time = a.time.compareTo(b.time);
    return time != 0 ? time : a.key.compareTo(b.key);
  });
  return {
    'scope': scope,
    'enabled': true,
    'reminders': reminders,
    'widget': {
      'date': today,
      'title': '今日安排',
      'lines': lines.take(4).map((line) => line.text).toList(),
      'route': '/today',
    },
  };
}
