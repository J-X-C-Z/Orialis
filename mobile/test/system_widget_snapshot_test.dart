import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_snapshot.dart';

Task _task(
  String id, {
  String? due,
  String? dueTime,
  bool completed = false,
  String? deletedAt,
}) => Task(
  id: id,
  title: id,
  due: due,
  dueTime: dueTime,
  completed: completed,
  deletedAt: deletedAt,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

CalendarEvent _event(
  String id, {
  required DateTime start,
  required DateTime end,
  bool allDay = false,
  String? deletedAt,
}) => CalendarEvent(
  id: id,
  title: id,
  startAt: start.toIso8601String(),
  endAt: end.toIso8601String(),
  allDay: allDay,
  important: false,
  reminderMinutes: 10,
  deletedAt: deletedAt,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

Map<Object?, Object?> _widget(
  List<Task> tasks,
  List<CalendarEvent> events,
  DateTime now,
) =>
    buildSystemSnapshot(
          scope: 'scope',
          tasks: tasks,
          events: events,
          now: now,
        )['widget']
        as Map<Object?, Object?>;

void main() {
  test('builds task and schedule summaries with stable ordering', () {
    final now = DateTime(2026, 10, 31, 12);
    final widget = _widget(
      [
        _task('overdue', due: '2026-10-30', dueTime: '10:00'),
        _task('todayMorning', due: '2026-10-31', dueTime: '09:00'),
        _task('todayNoTime', due: '2026-10-31'),
        _task('todayEvening', due: '2026-10-31', dueTime: '20:00'),
        _task('future', due: '2026-11-02', dueTime: '08:30'),
        _task('noDate'),
        _task(
          'completedToday',
          due: '2026-10-31',
          dueTime: '10:00',
          completed: true,
        ),
        _task(
          'deletedToday',
          due: '2026-10-31',
          dueTime: '11:00',
          deletedAt: '2026-10-31',
        ),
      ],
      [
        _event(
          'ongoingCross',
          start: DateTime(2026, 10, 30, 23),
          end: DateTime(2026, 10, 31, 13),
        ),
        _event(
          'endedToday',
          start: DateTime(2026, 10, 31, 8),
          end: DateTime(2026, 10, 31, 9),
        ),
        _event(
          'allDay',
          start: DateTime(2026, 10, 31),
          end: DateTime(2026, 10, 31),
          allDay: true,
        ),
        _event(
          'tomorrow',
          start: DateTime(2026, 11, 1, 9),
          end: DateTime(2026, 11, 1, 10),
        ),
        _event(
          'daySeven',
          start: DateTime(2026, 11, 6, 18),
          end: DateTime(2026, 11, 6, 19),
        ),
        _event(
          'dayEight',
          start: DateTime(2026, 11, 7, 9),
          end: DateTime(2026, 11, 7, 10),
        ),
        _event(
          'crossMonth',
          start: DateTime(2026, 10, 31, 22),
          end: DateTime(2026, 11, 2, 2),
        ),
        _event(
          'deleted',
          start: DateTime(2026, 10, 31, 15),
          end: DateTime(2026, 10, 31, 16),
          deletedAt: '2026-10-31',
        ),
      ],
      now,
    );

    expect(widget['date'], '2026-10-31');
    expect(widget['title'], '今日安排');
    expect(widget['route'], '/today');
    expect(widget['taskCount'], 6);
    expect(widget['todayTaskCount'], 3);
    expect(widget['scheduleCount'], 4);
    expect(widget['completedCount'], 1);
    expect(widget['calendarDays'], [30, 31]);
    expect(widget['lines'], contains('23:00 ongoingCross'));
    expect(widget['taskLines'], [
      '逾期 2026-10-30 10:00 overdue',
      '逾期 2026-10-31 09:00 todayMorning',
      '今日 20:00 todayEvening',
      '今日 todayNoTime',
      '2026-11-02 08:30 future',
      '无日期 noDate',
    ]);
    expect(widget['scheduleLines'], [
      '2026-10-30 23:00 ongoingCross',
      '2026-10-31 全天 allDay',
      '2026-10-31 22:00 crossMonth',
      '2026-11-01 09:00 tomorrow',
      '2026-11-06 18:00 daySeven',
    ]);
  });

  test('caps list fields while counts retain the full active data set', () {
    final now = DateTime(2026, 10, 31, 12);
    final tasks = [
      for (var index = 0; index < 15; index++)
        _task(
          'task-$index',
          due: '2026-11-${(index + 1).toString().padLeft(2, '0')}',
          dueTime: '09:00',
        ),
    ];
    final events = [
      for (var index = 0; index < 15; index++)
        _event(
          'event-$index',
          start: DateTime(2026, 11, 1, 8, index),
          end: DateTime(2026, 11, 1, 8, index + 30),
        ),
    ];
    final widget = _widget(tasks, events, now);

    expect(widget['taskCount'], 15);
    expect(widget['taskLines'], hasLength(12));
    expect(widget['scheduleLines'], hasLength(12));
  });

  test('caps legacy today lines with an independent same-day data set', () {
    final now = DateTime(2026, 10, 31, 12);
    final tasks = [
      for (var index = 0; index < 13; index++)
        _task(
          'today-$index',
          due: '2026-10-31',
          dueTime: '10:${index.toString().padLeft(2, '0')}',
        ),
    ];
    final widget = _widget(tasks, <CalendarEvent>[], now);

    expect(widget['taskCount'], 13);
    expect(widget['lines'], hasLength(12));
    expect(widget['taskLines'], hasLength(12));
  });

  test('handles empty lists missing dates and invalid schedule values', () {
    final now = DateTime(2026, 10, 31, 12);
    final empty = _widget(<Task>[], <CalendarEvent>[], now);
    expect(empty['lines'], isEmpty);
    expect(empty['taskLines'], isEmpty);
    expect(empty['scheduleLines'], isEmpty);
    expect(empty['taskCount'], 0);
    expect(empty['todayTaskCount'], 0);
    expect(empty['scheduleCount'], 0);
    expect(empty['completedCount'], 0);
    expect(empty['calendarDays'], isEmpty);

    final widget = _widget(
      [_task('undated')],
      [
        _event(
          'invalid',
          start: DateTime(2026, 10, 31, 13),
          end: DateTime(2026, 10, 31, 14),
        ).copyWith(startAt: ''),
        _event(
          'invalidEnd',
          start: DateTime(2026, 10, 31, 15),
          end: DateTime(2026, 10, 31, 16),
        ).copyWith(endAt: ''),
      ],
      now,
    );
    expect(widget['taskLines'], ['无日期 undated']);
    expect(widget['scheduleLines'], isEmpty);
    expect(widget['calendarDays'], isEmpty);
  });
}
