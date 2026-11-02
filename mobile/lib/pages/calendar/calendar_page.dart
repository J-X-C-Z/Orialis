import '../../app/design/mobile_motion.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;

import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_children.dart';
import '../../features/system_integration/schedule_tracking_button.dart';
import '../../features/events/presentation/task_editor.dart';
import '../shared/page_parts.dart';
import '../shared/adaptive_layout.dart';
import '../shared/glass_segmented.dart';
import 'calendar_week_view.dart';

typedef Schedule = CalendarEvent;

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({this.initialDate, this.initialScheduleId, super.key});
  final DateTime? initialDate;
  final String? initialScheduleId;
  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late DateTime _date = widget.initialDate ?? DateTime.now();
  bool _openedInitialSchedule = false;
  bool _collapseFreeHours = false;
  late int _view = widget.initialScheduleId == null ? 2 : 0;
  late final Stream<List<Schedule>> _schedules;
  late final Stream<List<Task>> _tasks;
  List<Schedule>? _indexedSchedules;
  List<Task>? _indexedTasks;
  String? _indexedMonth;
  final Map<String, List<Schedule>> _schedulesByDay = {};
  final Map<String, List<Task>> _tasksByDay = {};

  void _indexDates(List<Schedule> schedules, List<Task> tasks) {
    final month = '${_date.year}-${_date.month}';
    if (identical(schedules, _indexedSchedules) &&
        identical(tasks, _indexedTasks) &&
        month == _indexedMonth) {
      return;
    }
    _indexedSchedules = schedules;
    _indexedTasks = tasks;
    _indexedMonth = month;
    _schedulesByDay.clear();
    _tasksByDay.clear();
    // Include adjacent week days while bounding very long running schedules.
    final lower = DateTime(_date.year, _date.month, -6);
    final upper = DateTime(_date.year, _date.month + 1, 8);
    for (final schedule in schedules) {
      final start = DateTime.parse(schedule.startAt).toLocal();
      final end = DateTime.parse(schedule.endAt).toLocal();
      var day = DateTime(start.year, start.month, start.day);
      if (day.isBefore(lower)) day = lower;
      while (day.isBefore(end) && day.isBefore(upper)) {
        (_schedulesByDay[dateKey(day)] ??= []).add(schedule);
        day = DateTime(day.year, day.month, day.day + 1);
      }
    }
    for (final entries in _schedulesByDay.values) {
      entries.sort(
        (a, b) => a.allDay == b.allDay
            ? DateTime.parse(a.startAt).compareTo(DateTime.parse(b.startAt))
            : a.allDay
            ? -1
            : 1,
      );
    }
    for (final task in tasks) {
      if (!task.completed && task.due != null) {
        (_tasksByDay[task.due!] ??= []).add(task);
      }
    }
  }

  List<Schedule> _on(DateTime day) => _schedulesByDay[dateKey(day)] ?? const [];
  @override
  void initState() {
    super.initState();
    _schedules = ref.read(scheduleRepositoryProvider).watchAll();
    _tasks = ref.read(taskRepositoryProvider).watchTasks();
  }

  double _direction = 0;

  void _move(int direction) => setState(() {
    _direction = direction.toDouble();
    _date = _view == 2
        ? DateTime(_date.year, _date.month + direction, 1)
        : DateTime(
            _date.year,
            _date.month,
            _date.day + direction * (_view == 1 ? 7 : 1),
          );
  });

  Future<void> _edit([Schedule? event, DateTime? start]) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (_) => _ScheduleEditor(
        event: event,
        date: start ?? _date,
        initialStart: start,
        onSave: (d) async {
          final r = ref.read(scheduleRepositoryProvider);
          if (event == null) {
            await r.create(
              title: d.title,
              startAt: d.start,
              endAt: d.end,
              allDay: d.allDay,
              location: d.location,
              description: d.description,
              reminderMinutes: d.reminder,
              important: d.important,
            );
          } else {
            await r.update(
              event,
              title: d.title,
              startAt: d.start,
              endAt: d.end,
              allDay: d.allDay,
              location: d.location,
              description: d.description,
              reminderMinutes: d.reminder,
              important: d.important,
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: '日历',
    padding: EdgeInsets.zero,
    leading: widget.initialScheduleId == null
        ? null
        : LuminaIconButton(
            tooltip: '返回',
            icon: const LuminaIcon(LuminaIcons.back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
    floatingActionButton: _view == 1
        ? Semantics(
            toggled: _collapseFreeHours,
            child: LuminaIconButton(
              key: const ValueKey('calendar-fold-hours'),
              tooltip: _collapseFreeHours ? '展开空闲时段' : '折叠空闲时段',
              icon: AnimatedRotation(
                turns: _collapseFreeHours ? 0 : .5,
                duration: LuminaTheme.motionReducedOf(context)
                    ? Duration.zero
                    : LuminaMotion.standard,
                curve: luminaEaseOut,
                child: const LuminaIcon(LuminaIcons.chevronDown),
              ),
              onPressed: () =>
                  setState(() => _collapseFreeHours = !_collapseFreeHours),
            ),
          )
        : null,
    actions: [
      LuminaIconButton(
        tooltip: '新增日程',
        icon: const LuminaIcon(LuminaIcons.add),
        onPressed: () => _edit(),
      ),
    ],
    controls: ref.watch(desktopModeProvider)
        ? null
        : Transform.translate(
            offset: const Offset(0, -4),
            child: _mobileHeader(),
          ),
    controlsExtent: OrialisControlCard.extentOf(context),
    bodyBuilder: (context, topInset) => LayoutBuilder(
      builder: (context, constraints) {
        final desktop =
            ref.watch(desktopModeProvider) &&
            constraints.maxWidth >= 840 &&
            LuminaNavigationInset.of(context) == 0;
        if (desktop) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(width: 340, child: _dateNavigation()),
                    const SizedBox(width: 12),
                    LuminaButton(
                      primary: false,
                      onPressed: () => setState(() => _date = DateTime.now()),
                      child: const Text('今天'),
                    ),
                    const Spacer(),
                    SizedBox(width: 196, child: _viewSelector(desktop: true)),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(child: _calendarContent(0, desktop: true)),
              ],
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity.abs() < 250) return;
            _move(velocity < 0 ? 1 : -1);
          },
          child: OrialisContentTransition(
            changeKey: (
              _view,
              dateKey(
                _view == 1
                    ? DateTime(
                        _date.year,
                        _date.month,
                        _date.day - _date.weekday + 1,
                      )
                    : _view == 2
                    ? DateTime(_date.year, _date.month, 1)
                    : _date,
              ),
            ),
            direction: _direction,
            child: _calendarContent(
              topInset,
              adaptiveSplit:
                  (OrialisAdaptiveLayout.maybeOf(context)?.wide ?? false) &&
                  constraints.maxWidth >=
                      600 * MediaQuery.textScalerOf(context).scale(14) / 14,
            ),
          ),
        );
      },
    ),
  );

  Widget _mobileHeader() {
    if (OrialisAdaptiveLayout.maybeOf(context)?.wide ?? false) {
      return Column(
        key: const ValueKey('calendar-controls-card'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _viewSelector(),
          const SizedBox(height: 8),
          _compactDateNavigation(vertical: true),
        ],
      );
    }
    return OrialisControlCard(
      key: const ValueKey('calendar-controls-card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        key: const ValueKey('calendar-compact-header'),
        children: [
          Expanded(flex: 2, child: _viewSelector()),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: _compactDateNavigation()),
        ],
      ),
    );
  }

  Widget _compactDateNavigation({bool vertical = false}) {
    final previous = SizedBox.square(
      dimension: LuminaControlSize.minimum,
      child: LuminaIconButton(
        tooltip: _previousLabel,
        icon: const LuminaIcon(LuminaIcons.arrowLeft),
        onPressed: () => _move(-1),
      ),
    );
    final next = SizedBox.square(
      dimension: LuminaControlSize.minimum,
      child: LuminaIconButton(
        tooltip: _nextLabel,
        icon: const LuminaIcon(LuminaIcons.arrowRight),
        onPressed: () => _move(1),
      ),
    );
    final date = ConstrainedBox(
      key: const ValueKey('calendar-date-selector'),
      constraints: const BoxConstraints(minHeight: 44),
      child: LuminaSurface(
        glass: true,
        radius: LuminaControlSize.capsuleRadius,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        onTap: _selectDate,
        child: Center(
          child: Semantics(
            label: _dateLabel,
            button: true,
            child: Text(
              _view == 2
                  ? '${_date.year}/${_date.month}'
                  : '${_date.month}月${_date.day}日',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: LuminaTheme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      key: const ValueKey('calendar-date-navigation'),
      width: double.infinity,
      child: vertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: OrialisControlCard.extentOf(context) - 12,
                  child: date,
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  runSpacing: 8,
                  children: [previous, next],
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: previous),
                Expanded(child: date),
                Center(child: next),
              ],
            ),
    );
  }

  Widget _viewSelector({bool desktop = false}) => desktop
      ? LuminaSegmented<int>(
          key: const ValueKey('calendar-view-selector'),
          transparent: true,
          items: const {0: '日', 1: '周', 2: '月'},
          value: _view,
          onChanged: (v) => setState(() {
            _direction = (v - _view).sign.toDouble();
            _view = v;
          }),
        )
      : OrialisGlassSegmented<int>(
          key: const ValueKey('calendar-view-selector'),
          compact: true,
          direction: (OrialisAdaptiveLayout.maybeOf(context)?.wide ?? false)
              ? Axis.vertical
              : Axis.horizontal,
          stretch: true,
          items: const {0: '日', 1: '周', 2: '月'},
          value: _view,
          onChanged: (v) => setState(() {
            _direction = (v - _view).sign.toDouble();
            _view = v;
          }),
        );

  Widget _calendarContent(
    double topInset, {
    bool desktop = false,
    bool adaptiveSplit = false,
  }) => StreamBuilder<List<Schedule>>(
    stream: _schedules,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const PageFailure();
      if (!snapshot.hasData) {
        return const Center(child: LuminaProgress());
      }
      final all = snapshot.data!;
      if (!_openedInitialSchedule && widget.initialScheduleId != null) {
        _openedInitialSchedule = true;
        final target = all
            .where((s) => s.id == widget.initialScheduleId)
            .firstOrNull;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (target == null) {
            showLuminaMessage(context, '这条日程已不存在。');
          } else {
            _detail(target);
          }
        });
      }
      return StreamBuilder<List<Task>>(
        stream: _tasks,
        builder: (context, tasks) {
          if (tasks.hasError) return const PageFailure();
          _indexDates(all, tasks.data ?? const []);
          if (desktop) return _desktopCalendar();
          if (adaptiveSplit && _view != 1) return _adaptiveCalendar();
          return switch (_view) {
            1 => _week(topInset),
            2 => _month(topInset),
            _ => _day(topInset),
          };
        },
      );
    },
  );

  Widget _desktopCalendar() {
    if (_view == 1) return _weekTimeline(bottomInset: 80);
    if (_view == 0) {
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 760,
          child: ListView(
            key: const PageStorageKey('desktop-calendar-day'),
            padding: EdgeInsets.zero,
            children: [_dayFocus(), const SizedBox(height: 20), _agenda(_date)],
          ),
        ),
      );
    }
    return Row(
      key: const ValueKey('desktop-calendar-split'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            key: const PageStorageKey('desktop-calendar-grid'),
            primary: false,
            child: _desktopDateGrid(),
          ),
        ),
        const SizedBox(width: 24),
        SizedBox(
          width: 320,
          child: ListView(
            key: const PageStorageKey('desktop-calendar-agenda'),
            primary: false,
            padding: EdgeInsets.zero,
            children: [
              _agenda(_date),
              const SizedBox(height: 14),
              LuminaButton(
                primary: false,
                onPressed: () => _edit(),
                child: const Text('为这一天添加日程'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _desktopDateGrid() {
    final first = _view == 1
        ? DateTime(_date.year, _date.month, _date.day - _date.weekday + 1)
        : DateTime(_date.year, _date.month, 1);
    final offset = _view == 1 ? 0 : first.weekday - 1;
    final length = _view == 1
        ? 7
        : DateTime(_date.year, _date.month + 1, 0).day;
    final rows = ((offset + length) / 7).ceil();
    final theme = LuminaTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final day in ['周一', '周二', '周三', '周四', '周五', '周六', '周日'])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 12),
                  child: Text(day, style: theme.textTheme.bodySmall),
                ),
              ),
          ],
        ),
        for (var row = 0; row < rows; row++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var column = 0; column < 7; column++)
                  Expanded(
                    child: _desktopDateCell(
                      first.add(Duration(days: row * 7 + column - offset)),
                      outside:
                          row * 7 + column < offset ||
                          row * 7 + column >= offset + length,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        const QuietLabel('圆点 · 日程　菱形 · 截止事项'),
      ],
    );
  }

  Widget _desktopDateCell(DateTime day, {required bool outside}) {
    final theme = LuminaTheme.of(context);
    final selected = dateKey(day) == dateKey(_date);
    final today = dateKey(day) == dateKey(DateTime.now());
    final schedules = _on(day);
    final tasks = _dueOn(day);
    final summaries = <Widget>[
      for (final schedule in schedules.take(tasks.isEmpty ? 2 : 1))
        _monthSummary(schedule.title, false),
      for (final task in tasks.take(schedules.isEmpty ? 2 : 1))
        _monthSummary(task.title, true),
    ];
    final remaining = schedules.length + tasks.length - summaries.length;
    return Semantics(
      selected: selected,
      button: true,
      label: '${dateKey(day)}，${schedules.length} 条日程，${tasks.length} 项截止',
      child: LuminaTap(
        key: ValueKey('desktop-calendar-date-${dateKey(day)}'),
        onTap: () => setState(() => _date = day),
        child: Container(
          constraints: BoxConstraints(minHeight: _view == 1 ? 280 : 106),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: selected
                ? theme.colors.accentSoft
                : outside
                ? theme.colors.surface.withValues(alpha: .3)
                : theme.colors.surface.withValues(alpha: .6),
            border: Border.all(
              color: selected
                  ? theme.colors.accent.withValues(alpha: .6)
                  : theme.colors.muted.withValues(alpha: .12),
              width: .5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${day.day}',
                style: theme.textTheme.labelMedium.copyWith(
                  color: today || selected
                      ? theme.colors.accent
                      : outside
                      ? theme.colors.muted
                      : null,
                  fontWeight: today || selected ? FontWeight.w700 : null,
                ),
              ),
              const SizedBox(height: 10),
              for (final summary in summaries) ...[
                summary,
                const SizedBox(height: 3),
              ],
              if (remaining > 0)
                Text('+$remaining', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  String get _dateLabel =>
      '${_date.year}年${_date.month}月${_view == 2 ? '' : '${_date.day}日'}';
  String get _period => _view == 2
      ? '月'
      : _view == 1
      ? '周'
      : '天';
  String get _previousLabel => '上一$_period';
  String get _nextLabel => '下一$_period';

  Future<void> _selectDate() async {
    final date = await showLuminaDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) setState(() => _date = date);
  }

  Widget _dateNavigation() => LuminaDateNavigator(
    label: _dateLabel,
    previousLabel: _previousLabel,
    nextLabel: _nextLabel,
    onPrevious: () => _move(-1),
    onNext: () => _move(1),
    onSelectDate: _selectDate,
  );

  EdgeInsets _scrollInsets(double topInset) => EdgeInsets.only(
    top: topInset,
    left: 20,
    right: 20,
    bottom:
        24 +
        LuminaNavigationInset.of(context) +
        MediaQuery.paddingOf(context).bottom,
  );

  List<Task> _dueOn(DateTime day) => _tasksByDay[dateKey(day)] ?? const [];

  Color _statusColor(DateTime day, List<Schedule> schedules) {
    final tasks = _dueOn(day);
    final colors = LuminaTheme.of(context).colors;
    if (tasks.any((t) => t.important == true && t.urgent == true)) {
      return LuminaCardPalette.rose
          .colors(darkProgress: colors.darkProgress)
          .accent;
    }
    if (tasks.any((t) => t.urgent == true)) {
      return LuminaCardPalette.amber
          .colors(darkProgress: colors.darkProgress)
          .accent;
    }
    if (schedules.any((s) => s.important) ||
        tasks.any((t) => t.important == true)) {
      return LuminaCardPalette.ocean
          .colors(darkProgress: colors.darkProgress)
          .accent;
    }
    return LuminaCardPalette.sage
        .colors(darkProgress: colors.darkProgress)
        .accent;
  }

  Widget _agenda(DateTime day) {
    final schedules = _on(day);
    final due = _dueOn(day);
    return ContentStack(
      gap: 14,
      children: [
        LuminaPalette(
          palette: LuminaCardPalette.amber,
          child: LuminaSurface(
            key: ValueKey('calendar-due-${dateKey(day)}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: _categoryIcon(LuminaIcons.tasks, '当天截止'),
                ),
                const SizedBox(height: 14),
                if (due.isEmpty) const QuietLabel('这一天没有截止事项。'),
                if (due.isNotEmpty)
                  LuminaCompletionList(
                    animateChanges: true,
                    children: [
                      for (final task in due)
                        LuminaListRow(
                          key: ValueKey(task.id),
                          depth: LuminaSurfaceDepth.recessed,
                          title: task.title,
                          subtitle: task.dueTime ?? '当天截止',
                          detail: TaskSourceLabel(task: task),
                          trailing: LuminaCheck(
                            value: task.completed,
                            onChanged: (v) => ref
                                .read(taskRepositoryProvider)
                                .complete(task, v),
                          ),
                          onTap: () => showTaskEditor(
                            context,
                            task: task,
                            onSave: (d) => ref
                                .read(taskRepositoryProvider)
                                .updateDetails(
                                  task,
                                  title: d.title,
                                  notes: d.notes,
                                  due: d.due,
                                  dueTime: d.dueTime,
                                  important: d.important,
                                  urgent: d.urgent,
                                  reminderMinutes: d.reminderMinutes,
                                  recurrence: d.recurrence,
                                  projectId: d.projectId,
                                  reminderMinutesProvided: true,
                                  recurrenceProvided: true,
                                  projectIdProvided: true,
                                ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        LuminaPalette(
          palette: LuminaCardPalette.sage,
          child: LuminaTitledContentCard(
            key: ValueKey('calendar-schedules-${dateKey(day)}'),
            title: '${day.month}月${day.day}日 · 日程',
            emptyText: '这一天没有日程。',
            children: [
              for (final schedule in schedules) _scheduleRow(schedule),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryIcon(LuminaIcons icon, String label) =>
      Semantics(label: label, child: LuminaIcon(icon, size: 20));

  Widget _scheduleRow(Schedule s) {
    final start = DateTime.parse(s.startAt).toLocal();
    final end = DateTime.parse(s.endAt).toLocal();
    final now = DateTime.now();
    final ongoing = !s.allDay && !now.isBefore(start) && now.isBefore(end);
    final text = LuminaTheme.of(context).textTheme;
    final card = LuminaPalette(
      palette: s.important
          ? LuminaCardPalette.ocean
          : ongoing
          ? LuminaCardPalette.amber
          : LuminaCardPalette.sage,
      child: LuminaListRow(
        depth: LuminaSurfaceDepth.recessed,
        title: s.title,
        subtitle: [
          if (s.important) '重要',
          if (s.location?.isNotEmpty == true) s.location!,
          if (s.description?.isNotEmpty == true) s.description!,
        ].join(' · '),
        onTap: () => _detail(s),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (s.allDay)
                    _categoryIcon(LuminaIcons.calendar, '全天')
                  else
                    Text(
                      '${timeLabel(start)} — ${timeLabel(end)}${dateKey(start) != dateKey(end) ? ' · 跨日' : ''}',
                      style: text.labelMedium,
                    ),
                  if (ongoing)
                    Text(
                      '进行中',
                      style: text.labelSmall.copyWith(
                        color: LuminaTheme.of(context).colors.accent,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              card,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: MediaQuery.textScalerOf(context).scale(64).clamp(64, 96),
              child: Padding(
                padding: const EdgeInsets.only(top: 14, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.allDay)
                      _categoryIcon(LuminaIcons.calendar, '全天')
                    else
                      Text(timeLabel(start), style: text.labelMedium),
                    if (!s.allDay) ...[
                      Text('—', style: text.bodySmall),
                      Text(timeLabel(end), style: text.bodySmall),
                      if (dateKey(start) != dateKey(end))
                        Text('跨日', style: text.bodySmall),
                    ],
                    if (ongoing)
                      Text(
                        '进行中',
                        style: text.labelSmall.copyWith(
                          color: LuminaTheme.of(context).colors.accent,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: card),
          ],
        );
      },
    );
  }

  Widget _day(double topInset) => ListView(
    key: const PageStorageKey('calendar-day-scroll'),
    padding: _scrollInsets(topInset),
    children: [
      _dayFocus(),
      const SizedBox(height: 12),
      _agenda(_date),
      const SizedBox(height: 16),
      LuminaButton(
        primary: false,
        onPressed: () => setState(() => _date = DateTime.now()),
        child: const Text('回到今天'),
      ),
    ],
  );

  Widget _dayCell(DateTime day) {
    final events = _on(day);
    final due = _dueOn(day);
    final selected = dateKey(day) == dateKey(_date);
    final today = dateKey(day) == dateKey(DateTime.now());
    final theme = LuminaTheme.of(context);
    final colors = theme.colors;
    return Semantics(
      selected: selected,
      button: true,
      label:
          '${dateKey(day)}，${events.length} 条日程，${due.length} 项截止${today ? '，今天' : ''}',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selected ? 1 : 0),
        duration: LuminaTheme.motionReducedOf(context)
            ? Duration.zero
            : LuminaMotion.fast,
        curve: luminaEaseOut,
        builder: (context, selection, _) => LuminaSurface(
          key: ValueKey('calendar-date-month-${dateKey(day)}'),
          onTap: () => setState(() => _date = day),
          radius: 12,
          glass: true,
          diffuseGlass: true,
          color: Color.lerp(
            Color.lerp(
              colors.surface,
              colors.accent,
              day.weekday > 5 ? .07 : 0,
            ),
            colors.accentSoft,
            selection,
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Column(
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${day.day}',
                  maxLines: 1,
                  style: theme.textTheme.labelLarge.copyWith(
                    fontWeight: FontWeight.lerp(
                      today ? FontWeight.w700 : FontWeight.w500,
                      FontWeight.w700,
                      selection,
                    ),
                    color: Color.lerp(
                      today || day.weekday > 5 ? colors.accent : colors.ink,
                      colors.accent,
                      selection,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(
                height: 5,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (events.isNotEmpty)
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _statusColor(day, events),
                          shape: BoxShape.circle,
                        ),
                      ),
                    if (events.isNotEmpty && due.isNotEmpty)
                      const SizedBox(width: 4),
                    if (due.isNotEmpty)
                      Transform.rotate(
                        angle: .785398,
                        child: Container(
                          width: 4,
                          height: 4,
                          color: LuminaCardPalette.amber
                              .colors(darkProgress: colors.darkProgress)
                              .accent,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _weekTimeline({double topInset = 0, double bottomInset = 0}) =>
      CalendarWeekView(
        topInset: topInset,
        collapseFreeHours: _collapseFreeHours,
        bottomInset: bottomInset,
        date: _date,
        eventsOn: _on,
        tasksOn: _dueOn,
        onSelect: (day) => setState(() => _date = day),
        onEvent: _detail,
        onCreate: (start) {
          setState(() => _date = start);
          _edit(null, start);
        },
        onAgenda: (day) {
          setState(() => _date = day);
          showLuminaSheet<void>(
            context: context,
            builder: (_) => StreamBuilder<List<Schedule>>(
              stream: _schedules,
              builder: (context, schedules) => StreamBuilder<List<Task>>(
                stream: _tasks,
                builder: (context, tasks) {
                  if (schedules.hasError || tasks.hasError) {
                    return const PageFailure();
                  }
                  if (!schedules.hasData || !tasks.hasData) {
                    return const LuminaProgress();
                  }
                  _indexDates(schedules.data!, tasks.data!);
                  return _agenda(day);
                },
              ),
            ),
          );
        },
      );

  Widget _week(double topInset) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: _weekTimeline(
      topInset: topInset,
      bottomInset:
          12 +
          80 +
          LuminaNavigationInset.of(context) +
          MediaQuery.paddingOf(context).bottom,
    ),
  );

  Widget _dayFocus() {
    final theme = LuminaTheme.of(context);
    final today = dateKey(_date) == dateKey(DateTime.now());
    return LuminaSurface(
      key: const ValueKey('calendar-day-focus'),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${_date.day}'.padLeft(2, '0'),
            style: theme.textTheme.titleLarge.copyWith(fontSize: 48, height: 1),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${today ? '今天 · ' : ''}星期${['一', '二', '三', '四', '五', '六', '日'][_date.weekday - 1]}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_on(_date).length} 条日程  ·  ${_dueOn(_date).length} 项截止',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _monthAgenda() {
    final schedules = _on(_date);
    final due = _dueOn(_date);
    return LuminaSurface(
      key: const ValueKey('calendar-month-agenda'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_date.month}月${_date.day}日 · 日程',
            style: LuminaTheme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (schedules.isEmpty && due.isEmpty)
            const QuietLabel('当天暂无安排，留一点时间给自己。'),
          if (due.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  _categoryIcon(LuminaIcons.tasks, '当天截止'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      due.take(2).map((t) => t.title).join('、'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: LuminaTheme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          for (final event in schedules.take(3))
            LuminaTap(
              onTap: () => _detail(event),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 68,
                      child: event.allDay
                          ? _categoryIcon(LuminaIcons.calendar, '全天')
                          : QuietLabel(
                              timeLabel(
                                DateTime.parse(event.startAt).toLocal(),
                              ),
                            ),
                    ),
                    Expanded(
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          LuminaButton(
            primary: false,
            onPressed: () => setState(() {
              _direction = -1;
              _view = 0;
            }),
            child: Text(
              schedules.isEmpty && due.isEmpty ? '安排这一天' : '查看当天全部安排',
            ),
          ),
        ],
      ),
    );
  }

  Widget _adaptiveCalendar() => Padding(
    padding: const EdgeInsets.all(12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = (constraints.maxWidth * .46).clamp(320.0, 400.0);
        return Row(
          key: const ValueKey('adaptive-calendar-split'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: gridWidth,
              child: SingleChildScrollView(
                key: const PageStorageKey('adaptive-calendar-grid'),
                primary: false,
                child: _monthGrid(compact: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ListView(
                key: PageStorageKey(
                  'adaptive-calendar-agenda-${dateKey(_date)}',
                ),
                primary: false,
                padding: EdgeInsets.zero,
                children: [_agenda(_date)],
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _month(double topInset) => ListView(
    key: const PageStorageKey('calendar-month-scroll'),
    padding: _scrollInsets(topInset),
    children: [_monthGrid(), const SizedBox(height: 18), _monthAgenda()],
  );

  Widget _monthGrid({bool compact = false}) {
    final first = DateTime(_date.year, _date.month, 1);
    final length = DateTime(_date.year, _date.month + 1, 0).day;
    final rows = ((first.weekday - 1 + length) / 7).ceil();
    final cells = <Widget>[];
    for (var number = 1; number <= length; number++) {
      final day = DateTime(_date.year, _date.month, number);
      cells.add(_dayCell(day));
    }
    return LuminaSurface(
      padding: EdgeInsets.all(compact ? 8 : 16),
      child: Column(
        children: [
          Row(
            children: [
              for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(child: Center(child: QuietLabel(day))),
            ],
          ),
          const SizedBox(height: 8),
          for (var row = 0; row < rows; row++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < 7; column++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final index = row * 7 + column - first.weekday + 1;
                          if (index < 0 || index >= cells.length) {
                            return const SizedBox(height: 38);
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: cells[index],
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          const QuietLabel('圆点 · 日程　菱形 · 截止事项'),
        ],
      ),
    );
  }

  Widget _monthSummary(String title, bool deadline) =>
      LuminaCalendarSummary(title: title, deadline: deadline);

  Future<void> _detail(Schedule s) => showLuminaSheet<void>(
    context: context,
    builder: (sheetContext) => ContentStack(
      gap: 16,
      children: [
        Text(s.title, style: LuminaTheme.of(context).textTheme.titleLarge),
        Text(
          '${dateKey(DateTime.parse(s.startAt).toLocal())} · ${s.allDay ? '全天' : '${timeLabel(DateTime.parse(s.startAt).toLocal())} — ${timeLabel(DateTime.parse(s.endAt).toLocal())}'}',
        ),
        if (s.location != null) Text(s.location!),
        if (s.description != null) Text(s.description!),
        if (s.reminderMinutes != null)
          QuietLabel('提前 ${s.reminderMinutes} 分钟提醒'),
        if (s.important) const QuietLabel('重要日程'),
        ScheduleTrackingButton(eventId: s.id),
        const LuminaEngravedDivider(),
        TaskChildrenPanel(scheduleId: s.id, parentTitle: s.title),
        LuminaButton(
          onPressed: () {
            Navigator.pop(sheetContext);
            _edit(s);
          },
          child: const Text('编辑日程'),
        ),
        LuminaButton(
          primary: false,
          onPressed: () async {
            if (await confirmDelete(
              sheetContext,
              s.title,
              detail: '这次日程的附属事件也将一并删除。',
            )) {
              await ref.read(scheduleRepositoryProvider).delete(s);
              if (sheetContext.mounted) Navigator.pop(sheetContext);
            }
          },
          child: const Text('删除日程'),
        ),
      ],
    ),
  );
}

class _ScheduleDraft {
  const _ScheduleDraft({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.important,
    this.location,
    this.description,
    this.reminder,
  });
  final String title;
  final DateTime start, end;
  final bool allDay, important;
  final String? location, description;
  final int? reminder;
}

class _ScheduleEditor extends StatefulWidget {
  const _ScheduleEditor({
    this.event,
    this.initialStart,
    required this.date,
    required this.onSave,
  });
  final Schedule? event;
  final DateTime? initialStart;
  final DateTime date;
  final Future<void> Function(_ScheduleDraft) onSave;
  @override
  State<_ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<_ScheduleEditor> {
  late final _title = TextEditingController(text: widget.event?.title);
  late final _location = TextEditingController(text: widget.event?.location);
  late final _description = TextEditingController(
    text: widget.event?.description,
  );
  late final _reminder = TextEditingController(
    text: widget.event?.reminderMinutes?.toString(),
  );
  late DateTime _start = widget.event == null
      ? widget.initialStart ??
            DateTime(widget.date.year, widget.date.month, widget.date.day, 9)
      : DateTime.parse(widget.event!.startAt).toLocal();
  late DateTime _end = widget.event == null
      ? _start.add(const Duration(hours: 1))
      : widget.event!.allDay
      // Storage uses an exclusive end; the editor displays the last included day.
      ? DateTime.parse(widget.event!.endAt)
            .toLocal()
            .subtract(const Duration(microseconds: 1))
      : DateTime.parse(widget.event!.endAt).toLocal();
  late bool _allDay = widget.event?.allDay ?? false;
  late bool _important = widget.event?.important ?? false;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    for (final c in [_title, _location, _description, _reminder]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(bool start, bool time) async {
    final current = start ? _start : _end;
    final picked = time
        ? await showLuminaTimePicker(context: context, initialTime: current)
        : await showLuminaDatePicker(
            context: context,
            initialDate: current,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
    if (picked == null || !mounted) return;
    final result = time
        ? DateTime(
            current.year,
            current.month,
            current.day,
            picked.hour,
            picked.minute,
          )
        : DateTime(
            picked.year,
            picked.month,
            picked.day,
            current.hour,
            current.minute,
          );
    setState(() {
      if (start) {
        _start = result;
      } else {
        _end = result;
      }
    });
  }

  Future<void> _save() async {
    final r = int.tryParse(_reminder.text.trim());
    final start = _allDay
        ? DateTime(_start.year, _start.month, _start.day)
        : _start;
    final end = _allDay ? DateTime(_end.year, _end.month, _end.day + 1) : _end;
    if (_title.text.trim().isEmpty ||
        !start.isBefore(end) ||
        (_reminder.text.trim().isNotEmpty && (r == null || r < 0))) {
      setState(() => _error = '请填写标题，结束须晚于开始，提醒须为非负整数。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        _ScheduleDraft(
          title: _title.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          important: _important,
          location: _location.text.trim().isEmpty
              ? null
              : _location.text.trim(),
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          reminder: r,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ContentStack(
    gap: 16,
    children: [
      Text(
        widget.event == null ? '新增日程' : '编辑日程',
        style: LuminaTheme.of(context).textTheme.titleLarge,
      ),
      LuminaTextField(
        controller: _title,
        label: '标题',
        autofocus: widget.event == null,
      ),
      LuminaListRow(
        title: '全天',
        trailing: LuminaSwitch(
          value: _allDay,
          onChanged: (v) => setState(() => _allDay = v),
        ),
      ),
      for (final start in [true, false])
        Row(
          children: [
            Expanded(
              child: LuminaListRow(
                title: start ? '开始' : '结束',
                subtitle: dateKey(start ? _start : _end),
                onTap: () => _pick(start, false),
              ),
            ),
            if (!_allDay) ...[
              const SizedBox(width: 8),
              LuminaButton(
                primary: false,
                onPressed: () => _pick(start, true),
                child: Text(timeLabel(start ? _start : _end)),
              ),
            ],
          ],
        ),
      LuminaTextField(controller: _location, label: '地点'),
      LuminaListRow(
        title: '重要日程',
        trailing: LuminaSwitch(
          value: _important,
          onChanged: (v) => setState(() => _important = v),
        ),
      ),
      LuminaTextField(controller: _description, label: '描述', maxLines: 3),
      LuminaTextField(
        controller: _reminder,
        label: '提前提醒（分钟，可留空）',
        keyboardType: TextInputType.number,
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: LuminaTheme.of(context).colors.danger),
        ),
      LuminaButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
  );
}
