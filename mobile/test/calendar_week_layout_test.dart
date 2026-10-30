import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_layout.dart';

CalendarEvent event(
  String id,
  DateTime start,
  DateTime end, {
  bool allDay = false,
}) => CalendarEvent(
  id: id,
  title: id,
  startAt: start.toUtc().toIso8601String(),
  endAt: end.toUtc().toIso8601String(),
  allDay: allDay,
  important: false,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

void main() {
  final day = DateTime(2026, 12, 31);
  test('overlapping groups use lanes, adjacent events regain full width', () {
    final entries = layoutCalendarDay(day, [
      event('a', DateTime(2026, 12, 31, 9), DateTime(2026, 12, 31, 10)),
      event('b', DateTime(2026, 12, 31, 9, 30), DateTime(2026, 12, 31, 11)),
      event('c', DateTime(2026, 12, 31, 10), DateTime(2026, 12, 31, 10, 30)),
      event('d', DateTime(2026, 12, 31, 11), DateTime(2026, 12, 31, 12)),
    ]);
    expect(entries.map((e) => e.column), [0, 1, 0, 0]);
    expect(entries.map((e) => e.columns), [2, 2, 2, 1]);
    expect(entries[1].startMinute, 570);
  });

  test('cross-year midnight slices use exclusive ends and exclude all-day', () {
    final midnight = DateTime(2027, 1, 1);
    final crossing = event(
      'crossing',
      DateTime(2026, 12, 31, 23, 30),
      DateTime(2027, 1, 1, 0, 30),
    );
    final ending = event('ending', DateTime(2026, 12, 31, 23), midnight);
    final allDay = event('all-day', day, midnight, allDay: true);
    final previous = layoutCalendarDay(day, [crossing, ending, allDay]);
    expect(previous.length, 2);
    expect(previous.last.startMinute, 1410);
    expect(previous.last.endMinute, 1440);
    final next = layoutCalendarDay(midnight, [crossing, ending, allDay]);
    expect(next.length, 1);
    expect(next.single.event.id, 'crossing');
    expect(next.single.startMinute, 0);
    expect(next.single.endMinute, 30);
  });

  test('local day positions are independent of source timezone encoding', () {
    final from = DateTime(2026, 12, 31, 9, 15);
    final to = DateTime(2026, 12, 31, 10, 45);
    final utc = event('utc', from, to);
    final local = utc.copyWith(
      startAt: from.toIso8601String(),
      endAt: to.toIso8601String(),
    );
    expect(layoutCalendarDay(day, [utc]).single.startMinute, 555);
    expect(layoutCalendarDay(day, [local]).single.endMinute, 645);
  });
}
