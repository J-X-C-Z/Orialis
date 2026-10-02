import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_children.dart';
import '../../features/events/presentation/task_editor.dart';
import '../shared/page_parts.dart';

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
            ? a.startAt.compareTo(b.startAt)
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
  final _weekDayKeys = List.generate(7, (_) => GlobalKey());
  @override
  void initState() {
    super.initState();
    _schedules = ref.read(scheduleRepositoryProvider).watchAll();
    _tasks = ref.read(taskRepositoryProvider).watchTasks();
  }

  void _move(int direction) => setState(() {
    _date = _view == 2
        ? DateTime(_date.year, _date.month + direction, 1)
        : _date.add(Duration(days: direction * (_view == 1 ? 7 : 1)));
  });

  Future<void> _edit([Schedule? event]) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (_) => _ScheduleEditor(
        event: event,
        date: _date,
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
    actions: [
      LuminaIconButton(
        tooltip: '新增日程',
        icon: const LuminaIcon(LuminaIcons.add),
        onPressed: () => _edit(),
      ),
    ],
    body: LayoutBuilder(
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
                    SizedBox(width: 196, child: _viewSelector()),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(child: _calendarContent(0, desktop: true)),
              ],
            ),
          );
        }
        return LuminaFloatingHeader(
          header: _viewSelector(),
          bodyBuilder: (context, topInset) => _calendarContent(topInset),
        );
      },
    ),
  );

  Widget _viewSelector() => LuminaSegmented<int>(
    items: const {0: '日', 1: '周', 2: '月'},
    value: _view,
    onChanged: (v) => setState(() => _view = v),
  );

  Widget _calendarContent(double topInset, {bool desktop = false}) =>
      StreamBuilder<List<Schedule>>(
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
    if (_view == 0) {
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 760,
          child: ListView(
            key: const PageStorageKey('desktop-calendar-day'),
            padding: EdgeInsets.zero,
            children: [_agenda(_date)],
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

  Widget _dateNavigation() => LuminaDateNavigator(
    label: '${_date.year}年${_date.month}月${_view == 2 ? '' : '${_date.day}日'}',
    previousLabel:
        '上一${_view == 2
            ? '月'
            : _view == 1
            ? '周'
            : '天'}',
    nextLabel:
        '下一${_view == 2
            ? '月'
            : _view == 1
            ? '周'
            : '天'}',
    onPrevious: () => _move(-1),
    onNext: () => _move(1),
    onSelectDate: () async {
      final date = await showLuminaDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (date != null && mounted) setState(() => _date = date);
    },
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
    final dark = LuminaTheme.of(context).colors.dark;
    if (tasks.any((t) => t.important == true && t.urgent == true)) {
      return LuminaCardPalette.rose.colors(dark: dark).accent;
    }
    if (tasks.any((t) => t.urgent == true)) {
      return LuminaCardPalette.amber.colors(dark: dark).accent;
    }
    if (schedules.any((s) => s.important) ||
        tasks.any((t) => t.important == true)) {
      return LuminaCardPalette.ocean.colors(dark: dark).accent;
    }
    return LuminaTheme.of(context).colors.muted;
  }

  Widget _agenda(DateTime day) {
    final schedules = _on(day);
    final due = _dueOn(day);
    return ContentStack(
      gap: 14,
      children: [
        LuminaTitledContentCard(
          key: ValueKey('calendar-schedules-${dateKey(day)}'),
          title: '${day.month}月${day.day}日 · 日程',
          emptyText: '这一天没有日程。',
          children: [for (final schedule in schedules) _scheduleRow(schedule)],
        ),
        LuminaTitledContentCard(
          key: ValueKey('calendar-due-${dateKey(day)}'),
          title: '当天截止',
          emptyText: '这一天没有截止事项。',
          children: [
            if (due.isNotEmpty)
              LuminaCompletionList(
                animateChanges: true,
                children: [
                  for (final task in due)
                    OrialisListRow(
                      key: ValueKey(task.id),
                      depth: LuminaSurfaceDepth.recessed,
                      title: task.title,
                      subtitle: task.dueTime ?? '当天截止',
                      detail: TaskSourceLabel(task: task),
                      trailing: LuminaCheck(
                        value: task.completed,
                        onChanged: (v) =>
                            ref.read(taskRepositoryProvider).complete(task, v),
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
      ],
    );
  }

  Widget _scheduleRow(Schedule s) {
    final start = DateTime.parse(s.startAt).toLocal();
    final end = DateTime.parse(s.endAt).toLocal();
    final now = DateTime.now();
    final ongoing = !s.allDay && !now.isBefore(start) && now.isBefore(end);
    final text = LuminaTheme.of(context).textTheme;
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
                Text(
                  s.allDay ? '全天' : timeLabel(start),
                  style: text.labelMedium,
                ),
                if (!s.allDay) ...[
                  Text('—', style: text.bodySmall),
                  Text(timeLabel(end), style: text.bodySmall),
                  if (dateKey(start) != dateKey(end))
                    Text('跨日', style: text.bodySmall),
                ],
                if (ongoing)
                  Text(
                    '进行中',
                    style: text.labelSmall.copyWith(color: AppColors.accent),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LuminaPalette(
            palette: s.important
                ? LuminaCardPalette.ocean
                : LuminaCardPalette.mist,
            child: OrialisListRow(
              depth: LuminaSurfaceDepth.recessed,
              title: s.title,
              subtitle: [
                if (s.important) '重要',
                if (s.location?.isNotEmpty == true) s.location!,
                if (s.description?.isNotEmpty == true) s.description!,
              ].join(' · '),
              onTap: () => _detail(s),
            ),
          ),
        ),
      ],
    );
  }

  Widget _day(double topInset) => ListView(
    key: const PageStorageKey('calendar-day-scroll'),
    padding: _scrollInsets(topInset),
    children: [
      _dateNavigation(),
      const SizedBox(height: 16),
      _agenda(_date),
      const SizedBox(height: 16),
      LuminaButton(
        primary: false,
        onPressed: () => setState(() => _date = DateTime.now()),
        child: const Text('回到今天'),
      ),
    ],
  );

  Widget _dayCell(DateTime day, {bool week = false}) {
    final events = _on(day);
    final count = events.length + _dueOn(day).length;
    final selected = dateKey(day) == dateKey(_date);
    final colors = LuminaTheme.of(context).colors;
    final text = LuminaTheme.of(context).textTheme;
    final density = count == 0 ? 0.0 : (.06 + count.clamp(0, 6) * .025);
    return Semantics(
      selected: selected,
      label: '${dateKey(day)}，$count 项',
      child: LuminaSurface(
        key: ValueKey(
          'calendar-date-${week ? 'week' : 'month'}-${dateKey(day)}',
        ),
        radius: 12,
        glass: true,
        diffuseGlass: true,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        color: Color.lerp(
          colors.surface,
          colors.accent,
          selected ? .23 : density,
        ),
        onTap: () {
          setState(() => _date = day);
          if (week) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final target = _weekDayKeys[day.weekday - 1].currentContext;
              if (!mounted || target == null) return;
              Scrollable.ensureVisible(
                target,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : LuminaMotion.standard,
                curve: luminaEaseOut,
              );
            });
          }
        },
        child: SizedBox(
          height: MediaQuery.textScalerOf(context).scale(week ? 58 : 38),
          width: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (week)
                Text(
                  ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1],
                  maxLines: 1,
                  style: text.bodySmall,
                ),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${day.day}',
                    style: text.labelLarge,
                    maxLines: 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 5,
                child: count == 0
                    ? null
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: _statusColor(day, events),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: SizedBox(width: 5 + count.clamp(0, 5) * 2.0),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _week(double topInset) {
    final monday = DateTime(
      _date.year,
      _date.month,
      _date.day - _date.weekday + 1,
    );
    return SingleChildScrollView(
      padding: _scrollInsets(topInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dateNavigation(),
          const SizedBox(height: 16),
          LuminaSurface(
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _dayCell(
                        monday.add(Duration(days: i)),
                        week: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          for (var i = 0; i < 7; i++) ...[
            Builder(
              builder: (context) {
                final day = monday.add(Duration(days: i));
                return KeyedSubtree(key: _weekDayKeys[i], child: _agenda(day));
              },
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _month(double topInset) {
    final first = DateTime(_date.year, _date.month, 1);
    final length = DateTime(_date.year, _date.month + 1, 0).day;
    final cells = <Widget>[];
    final summaries = <Widget>[];
    for (var number = 1; number <= length; number++) {
      final day = DateTime(_date.year, _date.month, number);
      final schedules = _on(day);
      final due = _dueOn(day);
      final entries = <Widget>[];
      void addSchedule(Schedule schedule) =>
          entries.add(_monthSummary(schedule.title, false));
      void addTask(Task task) => entries.add(_monthSummary(task.title, true));
      if (schedules.isNotEmpty && due.isNotEmpty) {
        addSchedule(schedules.first);
        addTask(due.first);
      } else {
        for (final schedule in schedules.take(2)) {
          addSchedule(schedule);
        }
        for (final task in due.take(2)) {
          addTask(task);
        }
      }
      final remaining = schedules.length + due.length - entries.length;
      cells.add(_dayCell(day));
      summaries.add(
        Semantics(
          button: true,
          label: '${dateKey(day)} 详情',
          child: LuminaTap(
            onTap: () => setState(() => _date = day),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...entries,
                if (remaining > 0)
                  Text(
                    '+$remaining',
                    style: LuminaTheme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return ListView(
      key: const PageStorageKey('calendar-month-scroll'),
      padding: _scrollInsets(topInset),
      children: [
        _dateNavigation(),
        const SizedBox(height: 16),
        LuminaSurface(
          child: Column(
            children: [
              Row(
                children: [
                  for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                    Expanded(child: Center(child: QuietLabel(day))),
                ],
              ),
              const SizedBox(height: 8),
              _ExpandableMonthGrid(
                offset: first.weekday - 1,
                cells: cells,
                summaries: summaries,
              ),
              const QuietLabel('圆点 · 日程　菱形 · 截止事项'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _agenda(_date),
      ],
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

// Expansion state stays local: dragging does not rebuild date data or agendas.
class _ExpandableMonthGrid extends StatefulWidget {
  const _ExpandableMonthGrid({
    required this.offset,
    required this.cells,
    required this.summaries,
  });
  final int offset;
  final List<Widget> cells, summaries;
  @override
  State<_ExpandableMonthGrid> createState() => _ExpandableMonthGridState();
}

class _ExpandableMonthGridState extends State<_ExpandableMonthGrid> {
  double _expansion = 0, _shown = 0;
  bool _dragging = false;
  void _settle([double velocity = 0]) => setState(() {
    _dragging = false;
    _expansion = velocity.abs() > 250
        ? (velocity > 0 ? 1 : 0)
        : (_expansion >= .5 ? 1 : 0);
  });
  @override
  Widget build(BuildContext context) {
    final weeks = ((widget.cells.length + widget.offset) / 7).ceil();
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: _expansion),
          duration: _dragging || MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : LuminaMotion.standard,
          curve: luminaEaseOut,
          builder: (context, progress, _) {
            _shown = progress;
            return Column(
              children: [
                for (var row = 0; row < weeks; row++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final index = row * 7 + col - widget.offset;
                                if (index < 0 || index >= widget.cells.length) {
                                  return const SizedBox();
                                }
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      widget.cells[index],
                                      Offstage(
                                        offstage: progress == 0,
                                        child: ClipRect(
                                          child: Align(
                                            alignment: Alignment.topCenter,
                                            heightFactor: progress,
                                            child: Opacity(
                                              opacity: progress,
                                              child: SizedBox(
                                                height:
                                                    MediaQuery.textScalerOf(
                                                      context,
                                                    ).scale(64) +
                                                    12,
                                                child: widget.summaries[index],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => setState(() {
            _expansion = _shown;
            _dragging = true;
          }),
          onVerticalDragUpdate: (details) => setState(() {
            _expansion = (_expansion + details.delta.dy / 180).clamp(0.0, 1.0);
          }),
          onVerticalDragEnd: (details) => _settle(details.primaryVelocity ?? 0),
          onVerticalDragCancel: _settle,
          child: LuminaTap(
            onTap: () => setState(() => _expansion = _expansion < .5 ? 1 : 0),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RotatedBox(
                    quarterTurns: _expansion < .5 ? 0 : 2,
                    child: const LuminaIcon(LuminaIcons.chevronDown, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _expansion < .5 ? '展开月历' : '收起月历',
                    style: LuminaTheme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
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
  const _ScheduleEditor({this.event, required this.date, required this.onSave});
  final Schedule? event;
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
      ? DateTime(widget.date.year, widget.date.month, widget.date.day, 9)
      : DateTime.parse(widget.event!.startAt).toLocal();
  late DateTime _end = widget.event == null
      ? _start.add(const Duration(hours: 1))
      : widget.event!.allDay
      // Storage uses an exclusive end; the editor displays the last included day.
      ? DateTime.parse(
          widget.event!.endAt,
        ).toLocal().subtract(const Duration(microseconds: 1))
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
      OrialisListRow(
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
              child: OrialisListRow(
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
      OrialisListRow(
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
        Text(_error!, style: const TextStyle(color: AppColors.danger)),
      LuminaButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
  );
}
