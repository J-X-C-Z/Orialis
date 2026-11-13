import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart';

import '../../core/database/app_database.dart';
import '../shared/page_parts.dart';
import 'calendar_week_layout.dart';

/// Seven aligned days with floating dates and a shared, scrollable hour axis.
class CalendarWeekView extends StatefulWidget {
  const CalendarWeekView({
    required this.date,
    required this.eventsOn,
    required this.tasksOn,
    required this.onSelect,
    required this.onEvent,
    required this.onCreate,
    required this.onAgenda,
    this.bottomInset = 0,
    this.topInset = 0,
    this.collapseFreeHours = false,
    super.key,
  });
  final DateTime date;
  final List<CalendarEvent> Function(DateTime) eventsOn;
  final List<Task> Function(DateTime) tasksOn;
  final ValueChanged<DateTime> onSelect, onCreate, onAgenda;
  final ValueChanged<CalendarEvent> onEvent;
  final double bottomInset, topInset;
  final bool collapseFreeHours;

  @override
  State<CalendarWeekView> createState() => _CalendarWeekViewState();
}

class _CalendarWeekViewState extends State<CalendarWeekView>
    with SingleTickerProviderStateMixin {
  static const _hourHeight = 72.0;
  static const _gutter = 30.0;
  static const _selectionDuration = Duration(milliseconds: 200);
  late final ScrollController _hours = ScrollController(
    initialScrollOffset: widget.collapseFreeHours || _hasWeekInformation()
        ? 0
        : 8 * _hourHeight,
  );
  late DateTime _week;
  var _animateSelection = false;
  CalendarWeekAxis? _axis;
  double _flowHeight = 0;
  late final AnimationController _fold;

  static DateTime _startOfWeek(DateTime date) =>
      DateTime(date.year, date.month, date.day - date.weekday + 1);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _hasWeekInformation() {
    final start = _startOfWeek(widget.date);
    for (var i = 0; i < 7; i++) {
      final day = DateTime(start.year, start.month, start.day + i);
      if (widget.eventsOn(day).any((event) => event.allDay) ||
          widget.tasksOn(day).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _week = _startOfWeek(widget.date);
    _fold =
        AnimationController(
          vsync: this,
          value: widget.collapseFreeHours ? 1 : 0,
          duration: LuminaMotion.standard,
        )..addListener(() {
          _anchorAfterLayout();
          setState(() {});
        });
  }

  void _anchorAfterLayout() {
    if (!_hours.hasClients ||
        _axis == null ||
        _hours.position.isScrollingNotifier.value) {
      return;
    }
    if (_hours.offset <= _flowHeight) return;
    final minute = _axis!.minuteForOffset(_hours.offset - _flowHeight);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_hours.hasClients ||
          _hours.position.isScrollingNotifier.value) {
        return;
      }
      final offset = (_flowHeight + _axis!.offsetForMinute(minute)).clamp(
        0.0,
        _hours.position.maxScrollExtent,
      );
      if ((offset - _hours.offset).abs() > .01) _hours.jumpTo(offset);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LuminaTheme.motionReducedOf(context) && _fold.isAnimating) {
      _fold.value = widget.collapseFreeHours ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(CalendarWeekView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextWeek = _startOfWeek(widget.date);
    final changedWeek = !_sameDay(_week, nextWeek);
    _animateSelection =
        _sameDay(_week, nextWeek) && !_sameDay(oldWidget.date, widget.date);
    _week = nextWeek;
    if (changedWeek) _anchorAfterLayout();
    if (oldWidget.collapseFreeHours != widget.collapseFreeHours) {
      final target = widget.collapseFreeHours ? 1.0 : 0.0;
      if (LuminaTheme.motionReducedOf(context)) {
        _fold.value = target;
      } else {
        _fold.animateTo(
          target,
          duration: Duration(
            microseconds:
                (LuminaMotion.standard.inMicroseconds *
                        LuminaTheme.of(context).data.motionScale *
                        (target - _fold.value).abs())
                    .round(),
          ),
          curve: Curves.easeInOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _hours.dispose();
    _fold.dispose();
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
    final entries = [
      for (final day in days) layoutCalendarDay(day, widget.eventsOn(day)),
    ];
    final axis = CalendarWeekAxis(
      entries.expand((day) => day),
      collapseProgress: _fold.value,
      hourHeight: _hourHeight,
      gapHeight: math.max(28, scale * 18 + 8),
    );
    _axis = axis;
    final selectedColumn = widget.date.weekday - 1;
    final reduceMotion = LuminaTheme.motionReducedOf(context);
    double textHeight(TextStyle style) =>
        (MediaQuery.textScalerOf(context).scale(style.fontSize!) *
                (style.height ?? 1))
            .ceilToDouble();
    final dateHeight =
        textHeight(theme.textTheme.labelSmall) +
        textHeight(theme.textTheme.labelLarge) +
        5 +
        10 * theme.data.spacingScale;
    final laneHeight = math.max(
      44.0,
      textHeight(theme.textTheme.labelSmall) + 18,
    );
    _flowHeight = (hasAllDay ? laneHeight : 0) + (hasDue ? laneHeight : 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth, _gutter + 7 * 44 * scale);
        final dayWidth = (width - _gutter) / 7;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: width > constraints.maxWidth
              ? null
              : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: Stack(
              key: const ValueKey('calendar-week-timeline'),
              children: [
                Positioned.fill(
                  child: SingleChildScrollView(
                    key: const PageStorageKey('calendar-week-hours'),
                    controller: _hours,
                    padding: EdgeInsets.only(
                      top: widget.topInset + dateHeight + 4,
                      bottom: widget.bottomInset,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Column(
                          key: const ValueKey('calendar-week-information-flow'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasAllDay)
                              SizedBox(
                                height: laneHeight,
                                child: _headerLane('全天', dayWidth, [
                                  for (var i = 0; i < 7; i++)
                                    _allDaySymbol(
                                      days[i],
                                      allDay[i],
                                      laneHeight,
                                    ),
                                ]),
                              ),
                            if (hasDue)
                              SizedBox(
                                height: laneHeight,
                                child: _headerLane('截止', dayWidth, [
                                  for (final day in days)
                                    if (widget.tasksOn(day).isEmpty)
                                      const SizedBox()
                                    else
                                      _smallButton(
                                        key: ValueKey(
                                          'calendar-week-due-${dateKey(day)}',
                                        ),
                                        label:
                                            '${widget.tasksOn(day).length} 项截止：${widget.tasksOn(day).map((task) => task.title).join('、')}',
                                        icon: LuminaIcons.tasks,
                                        onTap: () => widget.onAgenda(day),
                                      ),
                                ]),
                              ),
                          ],
                        ),
                        SizedBox(
                          height: axis.extent + 20,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              for (final hour in {
                                for (final segment in axis.segments)
                                  segment.startMinute ~/ 60,
                                24,
                              }) ...[
                                Positioned(
                                  top: axis.offsetForMinute(hour * 60.0),
                                  left: 0,
                                  width: _gutter - 4,
                                  child: Text(
                                    hour.toString().padLeft(2, '0'),
                                    key: ValueKey('calendar-week-time-$hour'),
                                    textAlign: TextAlign.right,
                                    style: theme.textTheme.labelSmall.copyWith(
                                      fontSize: 10,
                                      height: 1,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: axis.offsetForMinute(hour * 60.0),
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
                              AnimatedPositioned(
                                left: _gutter + selectedColumn * dayWidth,
                                top: 0,
                                width: dayWidth,
                                height: axis.extent,
                                duration: reduceMotion || !_animateSelection
                                    ? Duration.zero
                                    : _selectionDuration,
                                curve: Curves.easeOutCubic,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    key: const ValueKey(
                                      'calendar-week-selection-bar',
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colors.accent.withValues(
                                        alpha: .035,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              for (var i = 0; i < 7; i++)
                                Positioned(
                                  top: 0,
                                  left: _gutter + i * dayWidth,
                                  width: dayWidth,
                                  height: axis.extent,
                                  child: _dayColumn(
                                    days[i],
                                    dayWidth,
                                    entries[i],
                                    axis,
                                  ),
                                ),
                              for (final gap in axis.segments.where(
                                (s) => s.collapsed,
                              ))
                                Positioned(
                                  top: gap.top,
                                  left: _gutter,
                                  right: 0,
                                  height: gap.height,
                                  child: IgnorePointer(
                                    child: Center(
                                      child: Text(
                                        '${gap.startMinute == 0 && gap.endMinute == 1440 ? '本周暂无定时日程 · ' : '空闲 · '}${_axisTime(gap.startMinute)}–${_axisTime(gap.endMinute)}',
                                        key: ValueKey(
                                          'calendar-week-gap-${gap.startMinute.toInt()}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            .copyWith(
                                              color: theme.colors.muted,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: widget.topInset,
                  left: 0,
                  right: 0,
                  child: Column(
                    key: const ValueKey('calendar-week-floating-header'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: dateHeight,
                        child: Row(
                          children: [
                            const SizedBox(width: _gutter),
                            for (final day in days)
                              SizedBox(
                                width: dayWidth,
                                child: _dateHeader(day),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _allDaySymbol(
    DateTime day,
    List<CalendarEvent> events,
    double height,
  ) {
    if (events.isEmpty) return const SizedBox();
    final single = events.length == 1;
    return Semantics(
      label: single
          ? '全天日程：${events.single.title}'
          : '全天日程：${events.length} 条，查看当天安排',
      button: true,
      child: LuminaTap(
        key: ValueKey(
          single
              ? 'calendar-week-allday-${dateKey(day)}-${events.single.id}'
              : 'calendar-week-allday-${dateKey(day)}',
        ),
        onTap: () =>
            single ? widget.onEvent(events.single) : widget.onAgenda(day),
        child: SizedBox(
          height: height,
          child: Center(
            child: LuminaIcon(
              single ? LuminaIcons.calendar : LuminaIcons.more,
              color: LuminaTheme.of(context).colors.accent,
            ),
          ),
        ),
      ),
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
              child: Semantics(
                label: label,
                child: LuminaIcon(
                  label == '全天' ? LuminaIcons.calendar : LuminaIcons.tasks,
                  size: 20,
                ),
              ),
            ),
          ),
          for (final child in children) SizedBox(width: dayWidth, child: child),
        ],
      );

  Widget _smallButton({
    Key? key,
    required String label,
    LuminaIcons? icon,
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
          child: icon == null
              ? Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                )
              : Semantics(label: label, child: LuminaIcon(icon, size: 20)),
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
              padding: const EdgeInsets.symmetric(vertical: 5),
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

  String _axisTime(double minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute.toInt() % 60).toString().padLeft(2, '0')}';

  Widget _dayColumn(
    DateTime day,
    double width,
    List<CalendarWeekEntry> entries,
    CalendarWeekAxis axis,
  ) {
    final theme = LuminaTheme.of(context);
    final now = DateTime.now();
    final isToday = dateKey(day) == dateKey(now);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: ValueKey('calendar-week-day-${dateKey(day)}'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              // Coordinate roundoff must not snap an exact half-hour backward.
              final minutes =
                  ((axis.minuteForOffset(details.localPosition.dy) + 1e-6) / 30)
                      .floor()
                      .clamp(0, 47) *
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
            top: axis.offsetForMinute(entry.startMinute),
            left: entry.column * width / entry.columns + 1,
            width: math.max(1, width / entry.columns - 2),
            height: math.max(
              4,
              axis.offsetForMinute(entry.endMinute) -
                  axis.offsetForMinute(entry.startMinute) -
                  1,
            ),
            child: _event(entry, day),
          ),
        if (isToday)
          Positioned(
            top: axis.offsetForMinute(now.hour * 60.0 + now.minute),
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
            depth: LuminaSurfaceDepth.raised,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final theme = LuminaTheme.of(context);
                final scaler = MediaQuery.textScalerOf(context);
                final titleStyle = theme.textTheme.labelSmall.copyWith(
                  fontSize: 12,
                  height: 1.25,
                  color: theme.colors.ink,
                );
                final lineHeight = scaler.scale(12) * 1.25;
                final lines = (constraints.maxHeight / lineHeight).floor();
                if (lines < 1) return const SizedBox();
                final titlePainter = TextPainter(
                  text: TextSpan(text: event.title, style: titleStyle),
                  textDirection: Directionality.of(context),
                  textScaler: scaler,
                )..layout(maxWidth: constraints.maxWidth);
                final detailLines = math.max(
                  0,
                  ((constraints.maxHeight - titlePainter.height - 3) /
                          (scaler.scale(10) * 1.25))
                      .floor(),
                );
                titlePainter.dispose();
                final details = [
                  '${timeLabel(start)}–${timeLabel(end)}',
                  if (event.location?.trim().isNotEmpty == true)
                    event.location!.trim(),
                  if (event.description?.trim().isNotEmpty == true)
                    event.description!.trim(),
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      maxLines: lines,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    if (detailLines > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        details.join('\n'),
                        maxLines: detailLines,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall.copyWith(
                          fontSize: 10,
                          height: 1.25,
                          color: theme.colors.muted,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
