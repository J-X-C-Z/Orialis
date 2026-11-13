import 'package:lumina_ui/lumina_ui.dart';

/// Human-facing deadline wording: relative near today, absolute further out.
class DueInfo {
  const DueInfo(
    this.label, {
    this.overdueDays = 0,
    this.today = false,
    this.lateToday = false,
  });
  final String label;
  final int overdueDays;
  final bool today;

  /// Due today at a time that has already passed.
  final bool lateToday;
  bool get overdue => overdueDays > 0 || lateToday;
}

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String weekdayLabel(DateTime day) => _weekdays[day.weekday - 1];

DateTime? _parseDay(String value) {
  final parts = value.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// [due] is a `yyyy-MM-dd` key and [dueTime] an optional `HH:mm`.
DueInfo? dueInfo(String? due, String? dueTime, DateTime now) {
  if (due == null) return null;
  final day = _parseDay(due);
  if (day == null) return DueInfo(dueTime == null ? due : '$due $dueTime');
  final today = DateTime(now.year, now.month, now.day);
  // Calendar-day difference; DST-safe because both sides are local midnights.
  final delta = DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final time = dueTime == null ? '' : ' $dueTime';
  final mondayOffset = today.weekday - 1;
  final String label;
  if (delta == 0) {
    label = '今天$time';
  } else if (delta == 1) {
    label = '明天$time';
  } else if (delta == 2) {
    label = '后天$time';
  } else if (delta == -1) {
    label = '昨天$time';
  } else if (delta > 0 && delta < 7 - mondayOffset) {
    label = '${weekdayLabel(day)}$time';
  } else if (delta > 0 && delta < 14 - mondayOffset) {
    label = '下${weekdayLabel(day)}$time';
  } else if (day.year == today.year) {
    label = '${day.month}月${day.day}日$time';
  } else {
    label = '${day.year}年${day.month}月${day.day}日$time';
  }
  var lateToday = false;
  if (delta == 0 && dueTime != null) {
    final parts = dueTime.split(':');
    final h = int.tryParse(parts.first), m = int.tryParse(parts.last);
    lateToday =
        h != null &&
        m != null &&
        DateTime(now.year, now.month, now.day, h, m).isBefore(now);
  }
  return DueInfo(
    label,
    overdueDays: delta < 0 ? -delta : 0,
    today: delta == 0,
    lateToday: lateToday,
  );
}

/// One-line deadline caption; overdue items use the danger tone plus text, so
/// the meaning never depends on colour alone.
class DueLabel extends StatelessWidget {
  const DueLabel({
    required this.due,
    required this.dueTime,
    this.emptyText,
    this.extra = const [],
    super.key,
  });
  final String? due, dueTime;
  final String? emptyText;
  final List<String> extra;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final info = dueInfo(due, dueTime, DateTime.now());
    final lead = info == null
        ? emptyText
        : [
            info.label,
            if (info.overdueDays > 0)
              '逾期 ${info.overdueDays} 天'
            else if (info.overdue)
              '已过时间',
          ].join(' · ');
    if (lead == null && extra.isEmpty) return const SizedBox.shrink();
    final style = theme.textTheme.bodySmall;
    // Only the deadline itself carries the tone; trailing notes such as the
    // local-save hint stay quiet so the soft card palette is not shouted over.
    final leadStyle = info != null && info.overdue
        ? style.copyWith(
            color: theme.colors.danger,
            fontWeight: FontWeight.w500,
          )
        : info != null && info.today
        ? style.copyWith(color: theme.colors.accent)
        : style;
    return Text.rich(
      TextSpan(
        children: [
          if (lead != null) TextSpan(text: lead, style: leadStyle),
          if (extra.isNotEmpty)
            TextSpan(text: '${lead == null ? '' : ' · '}${extra.join(' · ')}'),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

String _span(Duration d) {
  final minutes = d.inMinutes.clamp(1, 1 << 30);
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}

/// Where a timed schedule stands relative to [now], e.g. "25 分钟后开始".
String? scheduleCountdown(DateTime start, DateTime end, DateTime now) {
  if (!end.isAfter(now)) return null;
  if (!start.isAfter(now)) return '进行中 · 还剩 ${_span(end.difference(now))}';
  final until = start.difference(now);
  if (until.inHours >= 12) return null;
  return '${_span(until)}后开始';
}
