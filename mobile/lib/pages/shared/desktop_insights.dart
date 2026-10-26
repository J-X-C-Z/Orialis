import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../../app/app.dart';
import '../../core/database/app_database.dart';

/// A compact, live summary of the signed-in desktop account's local data.
class DesktopInsightsPanel extends ConsumerStatefulWidget {
  const DesktopInsightsPanel({super.key});

  @override
  ConsumerState<DesktopInsightsPanel> createState() =>
      _DesktopInsightsPanelState();
}

class _DesktopInsightsPanelState extends ConsumerState<DesktopInsightsPanel> {
  late Stream<List<Task>> _tasks;
  late Stream<List<CalendarEvent>> _schedules;

  @override
  void initState() {
    super.initState();
    _bindStreams();
  }

  void _bindStreams() {
    _tasks = ref.read(taskRepositoryProvider).watchTasks();
    _schedules = ref.read(scheduleRepositoryProvider).watchAll();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(taskRepositoryProvider, (_, repository) {
      setState(() => _tasks = repository.watchTasks());
    });
    ref.listen(scheduleRepositoryProvider, (_, repository) {
      setState(() => _schedules = repository.watchAll());
    });

    return StreamBuilder<List<Task>>(
      key: ObjectKey(_tasks),
      stream: _tasks,
      builder: (context, taskSnapshot) => StreamBuilder<List<CalendarEvent>>(
        key: ObjectKey(_schedules),
        stream: _schedules,
        builder: (context, scheduleSnapshot) {
          if (taskSnapshot.hasError || scheduleSnapshot.hasError) {
            return _message(context, '暂时无法读取本地数据');
          }
          if (!taskSnapshot.hasData || !scheduleSnapshot.hasData) {
            return const Center(child: LuminaProgress());
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _taskSummary(taskSnapshot.data!),
              const SizedBox(height: 12),
              _quadrants(taskSnapshot.data!),
              const SizedBox(height: 12),
              _upcoming(scheduleSnapshot.data!),
            ],
          );
        },
      ),
    );
  }

  Widget _taskSummary(List<Task> tasks) {
    final completed = tasks.where((task) => task.completed).length;
    final total = tasks.length;
    return _section(
      palette: LuminaCardPalette.sage,
      title: '任务完成',
      onTap: () => context.go('/events'),
      child: total == 0
          ? _empty(context, '还没有任务')
          : Row(
              children: [
                Semantics(
                  container: true,
                  label: '任务完成进度',
                  value: '已完成 $completed 项，共 $total 项',
                  child: ExcludeSemantics(
                    child: SizedBox.square(
                      dimension: 58,
                      child: CustomPaint(
                        painter: _CompletionRingPainter(
                          value: completed / total,
                          color: LuminaCardPalette.sage.colors(
                            dark: LuminaTheme.of(context).brightness == Brightness.dark,
                            darkProgress: LuminaTheme.of(context).darkProgress,
                          ).accent,
                          track: LuminaTheme.of(context).colors.outline,
                        ),
                        child: Center(
                          child: Text(
                            '${(completed * 100 / total).round()}%',
                            style: LuminaTheme.of(context)
                                .textTheme
                                .labelMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '已完成 $completed / $total 项',
                    style: LuminaTheme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _quadrants(List<Task> tasks) {
    final counts = List<int>.filled(5, 0);
    for (final task in tasks.where((task) => !task.completed)) {
      final index = switch ((task.important, task.urgent)) {
        (true, true) => 0,
        (true, false) => 1,
        (false, true) => 2,
        (false, false) => 3,
        _ => 4,
      };
      counts[index]++;
    }
    final total = counts.fold<int>(0, (sum, count) => sum + count);
    const labels = ['重要且紧急', '只重要', '只紧急', '普通', '未分类'];
    final theme = LuminaTheme.of(context);
    final colors = [
      theme.colors.danger,
      theme.colors.accent,
      LuminaCardPalette.amber
          .colors(
            dark: theme.brightness == Brightness.dark,
            darkProgress: theme.darkProgress,
          )
          .accent,
      theme.colors.muted,
      theme.colors.outline,
    ];

    return _section(
      palette: LuminaCardPalette.ocean,
      title: '未完成任务',
      onTap: () => context.go('/events'),
      child: total == 0
          ? _empty(context, '暂无未完成任务')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  container: true,
                  label: '未完成任务象限分布',
                  value: [
                    for (var i = 0; i < labels.length; i++)
                      '${labels[i]} ${counts[i]} 项',
                  ].join('，'),
                  child: ExcludeSemantics(
                    child: SizedBox(
                      height: 12,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: _StackedBarPainter(
                            values: counts,
                            colors: colors,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < labels.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: colors[i],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            labels[i],
                            style: theme.textTheme.bodySmall.copyWith(
                              color: theme.colors.ink,
                            ),
                          ),
                        ),
                        Text(
                          '${counts[i]}',
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _upcoming(List<CalendarEvent> schedules) {
    final now = DateTime.now();
    final upcoming =
        schedules
            .where(
              (schedule) =>
                  DateTime.parse(schedule.endAt).toLocal().isAfter(now),
            )
            .toList()
          ..sort(
            (a, b) =>
                DateTime.parse(a.startAt)
                    .toLocal()
                    .compareTo(DateTime.parse(b.startAt).toLocal()),
          );
    final visible = upcoming.take(3).toList();
    return _section(
      palette: LuminaCardPalette.amber,
      title: '接下来',
      onTap: () => context.go('/calendar'),
      child: visible.isEmpty
          ? _empty(context, '没有即将开始的日程')
          : Column(
              children: [
                for (var i = 0; i < visible.length; i++)
                  _scheduleRow(visible[i]),
              ],
            ),
    );
  }

  Widget _scheduleRow(CalendarEvent schedule) {
    final start = DateTime.parse(schedule.startAt).toLocal();
    final time = schedule.allDay
        ? '全天 · ${start.month}月${start.day}日'
        : '${start.month}月${start.day}日 · ${_twoDigits(start.hour)}:${_twoDigits(start.minute)}';
    final theme = LuminaTheme.of(context);
    return Semantics(
      button: true,
      label: '$time，${schedule.title}',
      child: LuminaTap(
        onTap: () => context.push(
          '/calendar/schedule/${Uri.encodeComponent(schedule.id)}?date=${_dateKey(start)}',
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 54,
                child: Text(
                  schedule.allDay
                      ? '全天'
                      : '${_twoDigits(start.hour)}:${_twoDigits(start.minute)}',
                  style: theme.textTheme.labelMedium.copyWith(
                    color: theme.colors.accent,
                  ),
                ),
              ),
              SizedBox(
                width: 14,
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: theme.colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(time, style: theme.textTheme.bodySmall),
                      Text(schedule.title, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section({
    required LuminaCardPalette palette,
    required String title,
    required VoidCallback onTap,
    required Widget child,
  }) => LuminaPalette(
    palette: palette,
    child: LuminaSurface(
      padding: const EdgeInsets.all(16),
      radius: 20,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: LuminaTheme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );

  Widget _empty(BuildContext context, String text) =>
      Text(text, style: LuminaTheme.of(context).textTheme.bodyMedium);

  Widget _message(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text, style: LuminaTheme.of(context).textTheme.bodyMedium),
    ),
  );

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';
}

class _CompletionRingPainter extends CustomPainter {
  const _CompletionRingPainter({
    required this.value,
    required this.color,
    required this.track,
  });

  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect.deflate(4),
      0,
      2 * 3.141592653589793,
      false,
      paint..color = track,
    );
    canvas.drawArc(
      rect.deflate(4),
      -3.141592653589793 / 2,
      2 * 3.141592653589793 * value,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_CompletionRingPainter oldDelegate) =>
      value != oldDelegate.value ||
      color != oldDelegate.color ||
      track != oldDelegate.track;
}

class _StackedBarPainter extends CustomPainter {
  const _StackedBarPainter({required this.values, required this.colors});

  final List<int> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (sum, value) => sum + value);
    if (total == 0) return;
    var left = 0.0;
    for (var i = 0; i < values.length; i++) {
      final width = size.width * values[i] / total;
      if (width == 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(left, 0, width, size.height),
        Paint()..color = colors[i],
      );
      left += width;
    }
  }

  @override
  bool shouldRepaint(_StackedBarPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) ||
      !listEquals(colors, oldDelegate.colors);
}
