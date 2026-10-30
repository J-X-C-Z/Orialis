/// Orders bounded snapshot candidates so relevant records are considered first.
class WearSnapshotOrdering {
  static void sort(
    Map<String, List<Map<String, Object?>>> candidates,
    DateTime now,
  ) {
    final today = _dateKey(now.toLocal());
    candidates['tasks']?.sort((a, b) {
      final aDue = _validDate(a['due']);
      final bDue = _validDate(b['due']);
      final aCompleted = a['completed'] == true;
      final bCompleted = b['completed'] == true;
      final aRank = aCompleted ? 4 : _taskRank(aDue, today);
      final bRank = bCompleted ? 4 : _taskRank(bDue, today);
      final rank = aRank.compareTo(bRank);
      if (rank != 0) return rank;
      if (aRank == 1) {
        final date = (bDue ?? '').compareTo(aDue ?? '');
        if (date != 0) return date;
      } else if (aRank == 2 || aRank == 0) {
        final date = (aDue ?? '').compareTo(bDue ?? '');
        if (date != 0) return date;
      }
      final position = _int(a['manualPosition'])
          .compareTo(_int(b['manualPosition']));
      return position != 0 ? position : _id(a).compareTo(_id(b));
    });

    candidates['schedules']?.sort((a, b) {
      final aStart = _instant(a['startAt']);
      final aEnd = _instant(a['endAt']);
      final bStart = _instant(b['startAt']);
      final bEnd = _instant(b['endAt']);
      final aRank = _scheduleRank(aStart, aEnd, now);
      final bRank = _scheduleRank(bStart, bEnd, now);
      final rank = aRank.compareTo(bRank);
      if (rank != 0) return rank;
      final aOrder = aRank == 2 ? aEnd : aStart;
      final bOrder = bRank == 2 ? bEnd : bStart;
      final order = aRank == 2
          ? (bOrder ?? DateTime(0)).compareTo(aOrder ?? DateTime(0))
          : (aOrder ?? DateTime(0)).compareTo(bOrder ?? DateTime(0));
      return order != 0 ? order : _id(a).compareTo(_id(b));
    });
  }

  static int _taskRank(String? due, String today) => due == null
      ? 3
      : due == today
      ? 0
      : due.compareTo(today) < 0
      ? 1
      : 2;

  static int _scheduleRank(DateTime? start, DateTime? end, DateTime now) {
    if (end == null || start == null) return 3;
    if (start.isAfter(now)) return 1;
    if (end.isAfter(now)) return 0;
    return 2;
  }

  static DateTime? _instant(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static String? _validDate(Object? value) =>
      value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
      ? value
      : null;

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static int _int(Object? value) => value is int ? value : 0x7fffffff;
  static String _id(Map<String, Object?> row) => row['id'] as String? ?? '';
}
