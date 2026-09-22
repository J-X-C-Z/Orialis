import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
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
  int _view = 0;
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
            stream: ref.watch(scheduleRepositoryProvider).watchAll(),
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
              return switch (_view) {
                1 => _week(all),
                2 => _month(all),
                _ => _day(all.where((s) => _occurs(s, _date)).toList()),
              };
            },
          ),
        ),
      ],
    ),
  );
  Widget _day(List<Schedule> events) => ListView(
    children: [
      ContentStack(
        gap: 16,
        children: [
          if (events.isEmpty)
            const OrialisEmptyState(text: '这一天还没有安排。\n为重要的事留一段时间。'),
          for (final s in events)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 58,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: QuietLabel(
                      s.allDay
                          ? '全天'
                          : timeLabel(DateTime.parse(s.startAt).toLocal()),
                    ),
                  ),
                ),
                Expanded(
                  child: LuminaSurface(
                    onTap: () => _detail(s),
                    child: ContentStack(
                      gap: 8,
                      children: [
                        Text(
                          s.title,
                          style: LuminaTheme.of(context).textTheme.titleMedium,
                        ),
                        QuietLabel(
                          s.allDay
                              ? '全天日程'
                              : '${timeLabel(DateTime.parse(s.startAt).toLocal())} — ${timeLabel(DateTime.parse(s.endAt).toLocal())}',
                        ),
                        if (s.location?.isNotEmpty == true)
                          QuietLabel(s.location!),
                        if (s.description?.isNotEmpty == true)
                          Text(
                            s.description!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          LuminaButton(
            primary: false,
            onPressed: () => setState(() => _date = DateTime.now()),
            child: const Text('回到今天'),
          ),
        ],
      ),
    ],
  );
  Widget _week(List<Schedule> all) {
    final monday = DateTime(
      _date.year,
      _date.month,
      _date.day - _date.weekday + 1,
    );
    return ListView(
      children: [
        ContentStack(
          children: [
            for (var i = 0; i < 7; i++)
              Builder(
                builder: (context) {
                  final day = monday.add(Duration(days: i));
                  final events = all.where((s) => _occurs(s, day)).toList();
                  return LuminaSurface(
                    onTap: () => setState(() {
                      _date = day;
                      _view = 0;
                    }),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 62,
                          child: ContentStack(
                            gap: 4,
                            children: [
                              QuietLabel(
                                ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][i],
                              ),
                              Text(
                                '${day.day}',
                                style: LuminaTheme.of(
                                  context,
                                ).textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ContentStack(
                            gap: 8,
                            children: [
                              if (events.isEmpty) const QuietLabel('无安排'),
                              for (final s in events)
                                OrialisListRow(
                                  title: s.title,
                                  subtitle: s.allDay
                                      ? '全天'
                                      : timeLabel(
                                          DateTime.parse(s.startAt).toLocal(),
                                        ),
                                  onTap: () => _detail(s),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _month(List<Schedule> all) {
    final first = DateTime(_date.year, _date.month, 1);
    final length = DateTime(_date.year, _date.month + 1, 0).day;
    final offset = first.weekday - 1;
    final weeks = ((length + offset) / 7).ceil();
    return SingleChildScrollView(
      child: ContentStack(
        gap: 8,
        children: [
          Row(
            children: [
              for (final d in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(child: Center(child: QuietLabel(d))),
            ],
          ),
          for (var row = 0; row < weeks; row++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final number = row * 7 + col - offset + 1;
                          if (number < 1 || number > length) {
                            return const SizedBox();
                          }
                          final day = DateTime(_date.year, _date.month, number);
                          final events = all
                              .where((s) => _occurs(s, day))
                              .toList();
                          return Padding(
                            padding: const EdgeInsets.all(2),
                            child: Semantics(
                              label:
                                  '${day.month}月$number日，${events.length}项日程',
                              button: true,
                              child: LuminaSurface(
                                radius: 12,
                                padding: const EdgeInsets.all(5),
                                onTap: () => setState(() {
                                  _date = day;
                                  _view = 0;
                                }),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 86,
                                  ),
                                  child: ContentStack(
                                    gap: 5,
                                    children: [
                                      Text(
                                        '$number',
                                        style: LuminaTheme.of(
                                          context,
                                        ).textTheme.labelMedium,
                                      ),
                                      for (final s in events.take(2))
                                        GestureDetector(
                                          onTap: () => _detail(s),
                                          child: Text(
                                            s.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: LuminaTheme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                      if (events.length > 2)
                                        QuietLabel('+${events.length - 2}'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
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
            if (await confirmDelete(sheetContext, s.title)) {
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
    this.location,
    this.description,
    this.reminder,
  });
  final String title;
  final DateTime start, end;
  final bool allDay;
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
      Row(
        children: [
          const Expanded(child: Text('全天')),
          LuminaSwitch(
            value: _allDay,
            onChanged: (v) => setState(() => _allDay = v),
          ),
        ],
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
