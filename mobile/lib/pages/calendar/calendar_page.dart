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
  double _monthExpansion = 0;
  double _shownMonthExpansion = 0;
  bool _draggingMonth = false;
  late final Stream<List<Schedule>> _schedules;
  late final Stream<List<Task>> _tasks;
  List<Task> _calendarTasks = const [];
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

  bool _occurs(Schedule s, DateTime day) {
    final start = DateTime.parse(s.startAt).toLocal(),
        end = DateTime.parse(s.endAt).toLocal();
    final midnight = DateTime(day.year, day.month, day.day);
    return start.isBefore(DateTime(day.year, day.month, day.day + 1)) &&
        end.isAfter(midnight);
  }

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
    body: Column(
      children: [
        LuminaSegmented<int>(
          items: const {0: '日', 1: '周', 2: '月'},
          value: _view,
          onChanged: (v) => setState(() => _view = v),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            LuminaIconButton(
              tooltip:
                  '上一${_view == 2
                      ? '月'
                      : _view == 1
                      ? '周'
                      : '天'}',
              icon: const LuminaIcon(LuminaIcons.back),
              onPressed: () => _move(-1),
            ),
            Expanded(
              child: LuminaButton(
                primary: false,
                onPressed: () async {
                  final d = await showLuminaDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null && mounted) setState(() => _date = d);
                },
                child: Text(
                  '${_date.year}年${_date.month}月${_view == 2 ? '' : '${_date.day}日'}',
                ),
              ),
            ),
            LuminaIconButton(
              tooltip:
                  '下一${_view == 2
                      ? '月'
                      : _view == 1
                      ? '周'
                      : '天'}',
              icon: const LuminaIcon(LuminaIcons.chevronRight),
              onPressed: () => _move(1),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: StreamBuilder<List<Schedule>>(
            stream: _schedules,
            builder: (context, snapshot) {
              if (snapshot.hasError) return const PageFailure();
              if (!snapshot.hasData) {
                return const Center(child: LuminaProgress());
              }
              final all = [...snapshot.data!]
                ..sort((a, b) => a.startAt.compareTo(b.startAt));
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
                  _calendarTasks = tasks.data ?? const [];
                  return switch (_view) {
                    1 => _week(all),
                    2 => _month(all),
                    _ => _day(all.where((s) => _occurs(s, _date)).toList()),
                  };
                },
              );
            },
          ),
        ),
      ],
    ),
  );
  EdgeInsets get _bottomInset => EdgeInsets.only(
    bottom:
        24 +
        LuminaNavigationInset.of(context) +
        MediaQuery.paddingOf(context).bottom,
  );

  List<Task> _dueOn(DateTime day) => _calendarTasks
      .where((t) => !t.completed && t.due == dateKey(day))
      .toList();

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

  Widget _agenda(List<Schedule> events, {bool individualCards = false}) {
    final sorted = [...events]
      ..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.startAt.compareTo(b.startAt);
      });
    final due = _dueOn(_date);
    final content = ContentStack(
      gap: 14,
      children: [
        if (sorted.isEmpty && due.isEmpty)
          const OrialisEmptyState(text: '这一天还没有安排。\n为重要的事留一段时间。'),
        for (final s in sorted)
          if (individualCards)
            LuminaCollapsibleCard(
              key: ValueKey('day-schedule-${s.id}'),
              storageId: 'calendar.schedule.${s.id}',
              title: s.title,
              child: ContentStack(
                children: [
                  _scheduleRow(s),
                  const LuminaEngravedDivider(),
                  TaskChildrenPanel(scheduleId: s.id, parentTitle: s.title),
                ],
              ),
            )
          else
            _scheduleRow(s),
        if (due.isNotEmpty) ...[
          const OrialisSectionHeader(title: '当天截止'),
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
      ],
    );
    return individualCards
        ? content
        : LuminaSurface(depth: LuminaSurfaceDepth.raised, child: content);
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

  Widget _day(List<Schedule> events) => ListView(
    padding: _bottomInset,
    children: [
      _agenda(events, individualCards: true),
      const SizedBox(height: 16),
      LuminaButton(
        primary: false,
        onPressed: () => setState(() => _date = DateTime.now()),
        child: const Text('回到今天'),
      ),
    ],
  );

  Widget _dayCell(DateTime day, List<Schedule> all, {bool week = false}) {
    final events = all.where((s) => _occurs(s, day)).toList();
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

  Widget _week(List<Schedule> all) {
    final monday = DateTime(
      _date.year,
      _date.month,
      _date.day - _date.weekday + 1,
    );
    return SingleChildScrollView(
      padding: _bottomInset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LuminaSurface(
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _dayCell(
                        monday.add(Duration(days: i)),
                        all,
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
                final schedules = all.where((s) => _occurs(s, day)).toList()
                  ..sort(
                    (a, b) => a.allDay == b.allDay
                        ? a.startAt.compareTo(b.startAt)
                        : a.allDay
                        ? -1
                        : 1,
                  );
                return KeyedSubtree(
                  key: _weekDayKeys[i],
                  child: LuminaCollapsibleCard(
                    key: ValueKey('week-day-${dateKey(day)}'),
                    storageId: 'calendar.week.${dateKey(day)}',
                    title:
                        '${day.month}月${day.day}日 · 周${['一', '二', '三', '四', '五', '六', '日'][i]}',
                    child: ContentStack(
                      children: [
                        if (schedules.isEmpty) const QuietLabel('这一天没有日程。'),
                        for (final schedule in schedules)
                          _scheduleRow(schedule),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _month(List<Schedule> all) {
    final first = DateTime(_date.year, _date.month, 1);
    final length = DateTime(_date.year, _date.month + 1, 0).day;
    final offset = first.weekday - 1;
    final weeks = ((length + offset) / 7).ceil();
    // Keep data filtering and static date widgets outside the animation tick.
    final cells = <int, Widget>{};
    final summaries = <int, List<String>>{};
    for (var number = 1; number <= length; number++) {
      final day = DateTime(_date.year, _date.month, number);
      cells[number] = _dayCell(day, all);
      summaries[number] = [
        ...all.where((s) => _occurs(s, day)).map((s) => s.title),
        ..._dueOn(day).map((t) => t.title),
      ];
    }
    return ListView(
      padding: _bottomInset,
      children: [
        LuminaSurface(
          child: Column(
            children: [
              Row(
                children: [
                  for (final d in ['一', '二', '三', '四', '五', '六', '日'])
                    Expanded(child: Center(child: QuietLabel(d))),
                ],
              ),
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween(end: _monthExpansion),
                duration:
                    _draggingMonth || MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : LuminaMotion.standard,
                curve: luminaEaseOut,
                builder: (context, progress, _) {
                  _shownMonthExpansion = progress;
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
                                      final number = row * 7 + col - offset + 1;
                                      if (number < 1 || number > length) {
                                        return const SizedBox();
                                      }
                                      final titles = summaries[number]!;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            cells[number]!,
                                            Offstage(
                                              offstage: progress == 0,
                                              child: ClipRect(
                                                child: Align(
                                                  alignment:
                                                      Alignment.topCenter,
                                                  heightFactor: progress,
                                                  child: Opacity(
                                                    opacity: progress,
                                                    child: SizedBox(
                                                      height:
                                                          MediaQuery.textScalerOf(
                                                            context,
                                                          ).scale(72),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .stretch,
                                                        children: [
                                                          if (titles.isNotEmpty)
                                                            LuminaSurface(
                                                              radius: 6,
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    3,
                                                                  ),
                                                              child: Text(
                                                                titles.first,
                                                                maxLines: 2,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style:
                                                                    LuminaTheme.of(
                                                                          context,
                                                                        )
                                                                        .textTheme
                                                                        .bodySmall,
                                                              ),
                                                            ),
                                                          if (titles.length > 1)
                                                            Text(
                                                              '+${titles.length - 1}',
                                                              style:
                                                                  LuminaTheme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .labelSmall,
                                                            ),
                                                        ],
                                                      ),
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
                  _monthExpansion = _shownMonthExpansion;
                  _draggingMonth = true;
                }),
                onVerticalDragUpdate: (details) => setState(
                  () => _monthExpansion =
                      (_monthExpansion + details.delta.dy / 180).clamp(
                        0.0,
                        1.0,
                      ),
                ),
                onVerticalDragEnd: (details) => setState(() {
                  _draggingMonth = false;
                  _monthExpansion = details.primaryVelocity!.abs() > 250
                      ? (details.primaryVelocity! > 0 ? 1 : 0)
                      : (_monthExpansion >= .5 ? 1 : 0);
                }),
                onVerticalDragCancel: () => setState(() {
                  _draggingMonth = false;
                  _monthExpansion = _monthExpansion >= .5 ? 1 : 0;
                }),
                child: LuminaTap(
                  onTap: () => setState(
                    () => _monthExpansion = _monthExpansion < .5 ? 1 : 0,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const LuminaIcon(LuminaIcons.chevronDown, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          _monthExpansion < .5 ? '展开月历' : '收起月历',
                          style: LuminaTheme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const QuietLabel('底色深浅表示繁忙程度 · 色点表示重要或紧急'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        OrialisSectionHeader(title: '${_date.month}月${_date.day}日'),
        _agenda(all.where((s) => _occurs(s, _date)).toList()),
      ],
    );
  }

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
