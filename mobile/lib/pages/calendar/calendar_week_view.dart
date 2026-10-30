import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart';

import '../../core/database/app_database.dart';
import '../shared/page_parts.dart';
import 'calendar_week_layout.dart';

/// Seven aligned days with a fixed date/all-day header and a shared hour axis.
class CalendarWeekView extends StatefulWidget {
  const CalendarWeekView({
    required this.date,
    required this.eventsOn,
    required this.tasksOn,
    required this.onSelect,
    required this.onEvent,
    required this.onCreate,
    required this.onAgenda,
    super.key,
  });
  final DateTime date;
  final List<CalendarEvent> Function(DateTime) eventsOn;
  final List<Task> Function(DateTime) tasksOn;
  final ValueChanged<DateTime> onSelect, onCreate, onAgenda;
  final ValueChanged<CalendarEvent> onEvent;

  @override
  State<CalendarWeekView> createState() => _CalendarWeekViewState();
}

class _CalendarWeekViewState extends State<CalendarWeekView> {
  static const _hourHeight = 72.0;
  static const _gutter = 42.0;
  late final ScrollController _hours = ScrollController(
    initialScrollOffset: 8 * _hourHeight,
  );

  @override
  void dispose() {
    _hours.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final monday = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day - widget.date.weekday + 1,
    );
    final days = List.generate(
      7,
      (i) => DateTime(monday.year, monday.month, monday.day + i),
    );
    final allDay = [
      for (final day in days)
        widget.eventsOn(day).where((e) => e.allDay).toList(),
    ];
    final hasAllDay = allDay.any((events) => events.isNotEmpty);
    final hasDue = days.any((day) => widget.tasksOn(day).isNotEmpty);
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return LayoutBuilder(
      builder: (context, constraints) {
        // At large text sizes allow horizontal scrolling instead of clipping text.
        final width = math.max(constraints.maxWidth, _gutter + 7 * 40 * scale);
        final dayWidth = (width - _gutter) / 7;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: width > constraints.maxWidth
              ? null
              : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: Column(
              key: const ValueKey('calendar-week-timeline'),
              children: [
                Row(
                  children: [
                    const SizedBox(width: _gutter),
                    for (final day in days)
                      SizedBox(width: dayWidth, child: _dateHeader(day)),
                  ],
                ),
                if (hasAllDay)
                  _headerLane('全天', dayWidth, [
                    for (var i = 0; i < 7; i++)
                      Column(
                        children: [
                          for (final event in allDay[i].take(2))
                            _smallButton(
                              key: ValueKey(
                                'calendar-week-allday-${dateKey(days[i])}-${event.id}',
                              ),
                              label: event.title,
                              onTap: () => widget.onEvent(event),
                            ),
                          if (allDay[i].length > 2)
                            _smallButton(
                              label: '+${allDay[i].length - 2}',
                              onTap: () => widget.onAgenda(days[i]),
                            ),
                        ],
                      ),
                  ]),
                if (hasDue)
                  _headerLane('截止', dayWidth, [
                    for (final day in days)
                      if (widget.tasksOn(day).isEmpty)
                        const SizedBox()
                      else
                        _smallButton(
                          key: ValueKey('calendar-week-due-${dateKey(day)}'),
                          label: '${widget.tasksOn(day).length} 项',
                          onTap: () => widget.onAgenda(day),
                        ),
                  ]),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    key: const PageStorageKey('calendar-week-hours'),
                    controller: _hours,
                    child: SizedBox(
                      height: 24 * _hourHeight + 20,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          for (var hour = 0; hour <= 24; hour++) ...[
                            Positioned(
                              top: hour * _hourHeight,
                              left: 0,
                              width: _gutter - 4,
                              child: Text(
                                '${hour.toString().padLeft(2, '0')}:00',
                                textAlign: TextAlign.right,
                                style: theme.textTheme.labelSmall.copyWith(
                                  fontSize: 10,
                                ),
                              ),
                            ),
                            Positioned(
                              top: hour * _hourHeight,
                              left: _gutter,
                              right: 0,
                              child: Container(
                                height: .5,
                                color: theme.colors.muted.withValues(
                                  alpha: .18,
                                ),
                              ),
                            ),
                          ],
                          for (var i = 0; i < 7; i++)
                            Positioned(
                              top: 0,
                              left: _gutter + i * dayWidth,
                              width: dayWidth,
                              height: 24 * _hourHeight,
                              child: _dayColumn(days[i], dayWidth),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _headerLane(String label, double dayWidth, List<Widget> children) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _gutter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                label,
                style: LuminaTheme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
          for (final child in children) SizedBox(width: dayWidth, child: child),
        ],
      );

  Widget _smallButton({
    Key? key,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = LuminaTheme.of(context);
    return LuminaTap(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: LuminaSurface(
          radius: 8,
          depth: LuminaSurfaceDepth.recessed,
          glass: true,
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ),
    );
  }

  Widget _dateHeader(DateTime day) {
    final theme = LuminaTheme.of(context);
    final selected = dateKey(day) == dateKey(widget.date);
    final today = dateKey(day) == dateKey(DateTime.now());
    return Semantics(
      selected: selected,
      button: true,
      label: '${dateKey(day)}${today ? '，今天' : ''}',
      child: LuminaTap(
        key: ValueKey('calendar-week-date-${dateKey(day)}'),
        onTap: () => widget.onSelect(day),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: selected ? 1 : 0),
            duration: LuminaTheme.motionReducedOf(context)
                ? Duration.zero
                : LuminaMotion.fast,
            curve: luminaEaseOut,
            builder: (context, selection, _) => LuminaSurface(
              radius: 12,
              glass: true,
              diffuseGlass: true,
              color: Color.lerp(
                theme.colors.surface,
                theme.colors.accentSoft,
                selection,
              ),
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Column(
                children: [
                  Text(
                    ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1],
                    style: theme.textTheme.labelSmall.copyWith(
                      color: Color.lerp(
                        theme.colors.muted,
                        theme.colors.accent,
                        selection,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${day.day}',
                    style: theme.textTheme.labelLarge.copyWith(
                      color: Color.lerp(
                        today || day.weekday > 5
                            ? theme.colors.accent
                            : theme.colors.ink,
                        theme.colors.accent,
                        selection,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayColumn(DateTime day, double width) {
    final theme = LuminaTheme.of(context);
    final entries = layoutCalendarDay(day, widget.eventsOn(day));
    final now = DateTime.now();
    final isToday = dateKey(day) == dateKey(now);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final minutes =
                  ((details.localPosition.dy / _hourHeight * 60) / 30).floor() *
                  30;
              widget.onCreate(
                DateTime(
                  day.year,
                  day.month,
                  day.day,
                  minutes ~/ 60,
                  minutes % 60,
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: dateKey(day) == dateKey(widget.date)
                    ? theme.colors.accent.withValues(alpha: .035)
                    : null,
                border: Border(
                  left: BorderSide(
                    color: theme.colors.muted.withValues(alpha: .15),
                    width: .5,
                  ),
                ),
              ),
            ),
          ),
        ),
        for (final entry in entries)
          Positioned(
            top: entry.startMinute / 60 * _hourHeight,
            left: entry.column * width / entry.columns + 1,
            width: math.max(1, width / entry.columns - 2),
            height: math.max(
              4,
              (entry.endMinute - entry.startMinute) / 60 * _hourHeight - 1,
            ),
            child: _event(entry, day),
          ),
        if (isToday)
          Positioned(
            top: (now.hour + now.minute / 60) * _hourHeight,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(height: 2, color: theme.colors.danger),
            ),
          ),
      ],
    );
  }

  Widget _event(CalendarWeekEntry entry, DateTime day) {
    final theme = LuminaTheme.of(context);
    final event = entry.event;
    final start = DateTime.parse(event.startAt).toLocal();
    final end = DateTime.parse(event.endAt).toLocal();
    return Semantics(
      button: true,
      label:
          '${event.title}，${dateKey(day)}，${timeLabel(start)} 至 ${timeLabel(end)}，${event.location ?? ''}',
      child: LuminaTap(
        key: ValueKey('calendar-week-event-${dateKey(day)}-${event.id}'),
        onTap: () => widget.onEvent(event),
        child: LuminaPalette(
          palette: event.important
              ? LuminaCardPalette.ocean
              : LuminaCardPalette.sage,
          child: LuminaSurface(
            radius: 8,
            depth: LuminaSurfaceDepth.recessed,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final lineHeight =
                    MediaQuery.textScalerOf(context).scale(12) * 1.25;
                final lines = (constraints.maxHeight / lineHeight).floor();
                if (lines < 1) return const SizedBox();
                final details = [
                  event.title,
                  if (constraints.maxWidth >= 52 &&
                      lines > 3 &&
                      event.location?.isNotEmpty == true)
                    event.location!,
                  if (constraints.maxWidth >= 52 && lines > 4) timeLabel(start),
                ];
                return Text(
                  details.join('\n'),
                  maxLines: lines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall.copyWith(
                    fontSize: 12,
                    height: 1.25,
                    color: theme.colors.ink,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
