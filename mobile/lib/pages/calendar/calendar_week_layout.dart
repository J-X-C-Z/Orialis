import '../../core/database/app_database.dart';

/// A local-day slice. End minutes are exclusive, including 1440 at midnight.
class CalendarWeekEntry {
  CalendarWeekEntry(this.event, this.startMinute, this.endMinute);
  final CalendarEvent event;
  final double startMinute, endMinute;
  int column = 0;
  int columns = 1;
}

List<CalendarWeekEntry> layoutCalendarDay(
  DateTime day,
  List<CalendarEvent> events,
) {
  final start = DateTime(day.year, day.month, day.day);
  final end = DateTime(day.year, day.month, day.day + 1);
  double minute(DateTime value) =>
      value.hour * 60 + value.minute + value.second / 60;
  final entries = <CalendarWeekEntry>[];
  for (final event in events) {
    if (event.allDay) continue;
    final from = DateTime.parse(event.startAt).toLocal();
    final to = DateTime.parse(event.endAt).toLocal();
    if (!from.isBefore(end) || !to.isAfter(start) || !to.isAfter(from)) {
      continue;
    }
    entries.add(
      CalendarWeekEntry(
        event,
        from.isBefore(start) ? 0 : minute(from),
        !to.isBefore(end) ? 1440 : minute(to),
      ),
    );
  }
  entries.sort((a, b) {
    final order = a.startMinute.compareTo(b.startMinute);
    return order != 0 ? order : b.endMinute.compareTo(a.endMinute);
  });
  final group = <CalendarWeekEntry>[];
  final ends = <double>[];
  var groupEnd = -1.0;
  void finishGroup() {
    for (final entry in group) {
      entry.columns = ends.length;
    }
    group.clear();
    ends.clear();
  }

  for (final entry in entries) {
    if (entry.startMinute >= groupEnd) finishGroup();
    var column = ends.indexWhere((end) => end <= entry.startMinute);
    if (column < 0) {
      column = ends.length;
      ends.add(entry.endMinute);
    } else {
      ends[column] = entry.endMinute;
    }
    entry.column = column;
    group.add(entry);
    if (group.length == 1 || entry.endMinute > groupEnd) {
      groupEnd = entry.endMinute;
    }
  }
  finishGroup();
  return entries;
}
