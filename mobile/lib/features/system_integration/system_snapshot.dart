import '../../core/database/app_database.dart';

String systemDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime _dayStart(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _nextDay(DateTime date) =>
    DateTime(date.year, date.month, date.day + 1);

({int hour, int minute, int second})? _taskTime(Task task) {
  final match = RegExp(r'^(\d{2}):(\d{2})(?::(\d{2}))?$')
      .firstMatch(task.dueTime ?? '');
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  final second = int.parse(match[3] ?? '0');
  if (hour > 23 || minute > 59 || second > 59) return null;
  return (hour: hour, minute: minute, second: second);
}

DateTime? _taskDueDate(Task task) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(task.due ?? '');
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final result = DateTime(year, month, day);
  if (result.year != year || result.month != month || result.day != day) {
    return null;
  }
  return result;
}

/// Task deadlines are wall-clock dates, unlike ISO Schedule instants.
DateTime? taskDeadline(Task task) {
  final date = _taskDueDate(task);
  final time = _taskTime(task);
  if (date == null || time == null) return null;
  return DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
    time.second,
  );
}

String taskSystemRoute(String id) => '/events';
String scheduleSystemRoute(String id, DateTime date) =>
    '/calendar/schedule/${Uri.encodeComponent(id)}?date=${systemDate(date.toLocal())}';

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _taskLine(Task task, DateTime now) {
  final dueDate = _taskDueDate(task);
  if (dueDate == null) return '无日期 ${task.title}';
  final deadline = taskDeadline(task);
  final today = _dayStart(now.toLocal());
  if (deadline != null && deadline.isBefore(now.toLocal())) {
    return '逾期 ${systemDate(deadline)} '
        '${_twoDigits(deadline.hour)}:${_twoDigits(deadline.minute)} '
        '${task.title}';
  }
  if (dueDate == today) {
    if (deadline == null) return '今日 ${task.title}';
    return '今日 ${_twoDigits(deadline.hour)}:${_twoDigits(deadline.minute)} '
        '${task.title}';
  }
  if (dueDate.isBefore(today)) return '逾期 ${systemDate(dueDate)} ${task.title}';
  if (deadline == null) return '${systemDate(dueDate)} ${task.title}';
  return '${systemDate(deadline)} '
      '${_twoDigits(deadline.hour)}:${_twoDigits(deadline.minute)} '
      '${task.title}';
}

DateTime _taskSortTime(Task task) {
  final deadline = taskDeadline(task);
  if (deadline != null) return deadline;
  final dueDate = _taskDueDate(task);
  if (dueDate == null) return DateTime(9999);
  return DateTime(dueDate.year, dueDate.month, dueDate.day, 23, 59, 59);
}

typedef _WidgetSchedule = ({CalendarEvent event, DateTime start, DateTime end});

DateTime _scheduleCoverageEnd(_WidgetSchedule schedule) {
  if (schedule.end.isAfter(schedule.start)) return schedule.end;
  return _nextDay(_dayStart(schedule.start));
}

bool _scheduleCoversDay(
  _WidgetSchedule schedule,
  DateTime dayStart,
  DateTime dayEnd,
) {
  if (schedule.end.isAfter(schedule.start)) {
    return schedule.start.isBefore(dayEnd) && schedule.end.isAfter(dayStart);
  }
  return !schedule.start.isBefore(dayStart) && schedule.start.isBefore(dayEnd);
}

String _scheduleLine(_WidgetSchedule schedule) {
  final localStart = schedule.start.toLocal();
  final time = schedule.event.allDay
      ? '全天'
      : '${_twoDigits(localStart.hour)}:${_twoDigits(localStart.minute)}';
  return '${systemDate(localStart)} $time ${schedule.event.title}';
}

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
  final localNow = now.toLocal();
  final todayStart = _dayStart(localNow);
  final tomorrowStart = _nextDay(todayStart);
  final weekEnd = DateTime(localNow.year, localNow.month, localNow.day + 7);
  final today = systemDate(localNow);
  final reminders = <Map<String, Object?>>[];
  final liveSchedules = <Map<String, Object?>>[];
  final lines = <({DateTime time, String key, String text})>[];
  final widgetSchedules = <_WidgetSchedule>[];
  final activeTasks = tasks
      .where((task) => task.deletedAt == null && !task.completed)
      .toList();
  final todayTaskCount = activeTasks.where((task) {
    return _taskDueDate(task) == todayStart;
  }).length;
  final completedCount = tasks.where((task) {
    return task.deletedAt == null &&
        task.completed &&
        _taskDueDate(task) == todayStart;
  }).length;
  activeTasks.sort((a, b) {
    final time = _taskSortTime(a).compareTo(_taskSortTime(b));
    return time != 0 ? time : a.id.compareTo(b.id);
  });
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
    final end = DateTime.tryParse(event.endAt);
    final schedule = end == null
        ? null
        : (event: event, start: local, end: end.toLocal());
    if (schedule != null) {
      widgetSchedules.add(schedule);
    }
    if (end != null && !start.isAfter(now) && end.isAfter(now)) {
      liveSchedules.add({
        'id': event.id,
        'title': event.title,
        'startsAtMillis': start.millisecondsSinceEpoch,
        'endsAtMillis': end.millisecondsSinceEpoch,
        'route': scheduleSystemRoute(event.id, local),
        'allDay': event.allDay,
      });
    }
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
          'endsAtMillis': DateTime.tryParse(event.endAt)
              ?.millisecondsSinceEpoch,
          'important': event.important,
          'allDay': event.allDay,
        });
      }
    }
    if (systemDate(local) == today ||
        (schedule != null &&
            _scheduleCoversDay(schedule, todayStart, tomorrowStart))) {
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
  final todaySchedules = widgetSchedules.where((schedule) {
    return _scheduleCoversDay(schedule, todayStart, tomorrowStart);
  }).toList();
  final upcomingSchedules =
      widgetSchedules.where((schedule) {
        final active = schedule.event.allDay
            ? _scheduleCoverageEnd(schedule).isAfter(localNow)
            : schedule.end.isAfter(localNow);
        if (!active || !schedule.start.isBefore(weekEnd)) return false;
        if (schedule.end.isAfter(schedule.start)) {
          return schedule.end.isAfter(todayStart);
        }
        return !schedule.start.isBefore(todayStart);
      }).toList()..sort((a, b) {
        final time = a.start.compareTo(b.start);
        return time != 0 ? time : a.event.id.compareTo(b.event.id);
      });
  final calendarDays = <int>{};
  final monthStart = DateTime(localNow.year, localNow.month);
  final monthEnd = DateTime(localNow.year, localNow.month + 1);
  for (final schedule in widgetSchedules) {
    var cursor = _dayStart(schedule.start);
    final coverageEnd = _scheduleCoverageEnd(schedule);
    if (cursor.isBefore(monthStart)) cursor = monthStart;
    final clippedEnd = coverageEnd.isAfter(monthEnd) ? monthEnd : coverageEnd;
    while (cursor.isBefore(clippedEnd)) {
      calendarDays.add(cursor.day);
      cursor = _nextDay(cursor);
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
    'liveSchedules': liveSchedules,
    'widget': {
      'date': today,
      'title': '今日安排',
      'lines': lines.take(12).map((line) => line.text).toList(),
      'taskLines': activeTasks
          .take(12)
          .map((task) => _taskLine(task, localNow))
          .toList(),
      'scheduleLines': upcomingSchedules.take(12).map(_scheduleLine).toList(),
      'taskCount': activeTasks.length,
      'todayTaskCount': todayTaskCount,
      'scheduleCount': todaySchedules.length,
      'completedCount': completedCount,
      'calendarDays': calendarDays.toList()..sort(),
      'route': '/today',
    },
  };
}
