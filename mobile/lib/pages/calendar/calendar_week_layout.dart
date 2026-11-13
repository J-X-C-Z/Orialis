import '../../core/database/app_database.dart';

/// Shared time coordinates for all seven columns; only wholly free hours fold.
class CalendarWeekAxis {
  CalendarWeekAxis(
    Iterable<CalendarWeekEntry> entries, {
    bool collapsed = false,
    double? collapseProgress,
    double hourHeight = 72,
    double gapHeight = 28,
  }) {
    final progress = (collapseProgress ?? (collapsed ? 1.0 : 0.0)).clamp(
      0.0,
      1.0,
    );
    final busy = List.filled(24, false);
    for (final entry in entries) {
      for (var hour = 0; hour < 24; hour++) {
        if (entry.startMinute < (hour + 1) * 60 &&
            entry.endMinute > hour * 60) {
          busy[hour] = true;
        }
      }
    }
    for (var hour = 0; hour < 24;) {
      final start = hour;
      final folded = progress > 0 && !busy[hour];
      hour++;
      if (folded) {
        while (hour < 24 && !busy[hour]) {
          hour++;
        }
      }
      final fullHeight = (hour - start) * hourHeight;
      final height = folded
          ? fullHeight + (gapHeight - fullHeight) * progress
          : fullHeight;
      segments.add((
        startMinute: start * 60.0,
        endMinute: hour * 60.0,
        top: extent,
        height: height,
        collapsed: folded,
      ));
      extent += height;
    }
  }

  final segments =
      <
        ({
          double startMinute,
          double endMinute,
          double top,
          double height,
          bool collapsed,
        })
      >[];
  double extent = 0;

  double offsetForMinute(double minute) {
    final value = minute.clamp(0.0, 1440.0);
    for (final segment in segments) {
      if (value <= segment.endMinute) {
        return segment.top +
            (value - segment.startMinute) /
                (segment.endMinute - segment.startMinute) *
                segment.height;
      }
    }
    return extent;
  }

  double minuteForOffset(double offset) {
    final value = offset.clamp(0.0, extent);
    for (final segment in segments) {
      if (value <= segment.top + segment.height) {
        return segment.startMinute +
            (value - segment.top) /
                segment.height *
                (segment.endMinute - segment.startMinute);
      }
    }
    return 1440;
  }
}

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
