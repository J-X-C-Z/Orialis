import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/task_children.dart';
import '../../features/events/presentation/long_press_orderable.dart';
import '../shared/page_parts.dart';

class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});
  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage> {
  late final Timer _clock;
  late final Stream<List<Task>> _tasksStream;
  Stream<List<CalendarEvent>>? _schedulesStream;
  String? _schedulesDay;

  @override
  void initState() {
    super.initState();
    // Hold one long-lived stream: rebuilding the page must not resubscribe
    // Drift watches every minute tick.
    _tasksStream = ref
        .read(taskRepositoryProvider)
        .watchTasksByFilters(completed: false);
    // Minute ticks refresh the "next schedule" window; stream resubscription
    // is avoided by caching the watch above and the day-scoped schedule watch.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Stream<List<CalendarEvent>> _schedulesFor(DateTime now) {
    final day = dateKey(now);
    final existing = _schedulesStream;
    if (existing != null && _schedulesDay == day) return existing;
    _schedulesDay = day;
    return _schedulesStream = ref
        .read(scheduleRepositoryProvider)
        .watchForDate(DateTime(now.year, now.month, now.day));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now(), key = dateKey(now);
    return OrialisPageScaffold(
      title: '今日',
      padding: EdgeInsets.zero,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: QuietLabel('${now.month}月${now.day}日'),
        ),
      ],
      body: StreamBuilder<List<Task>>(
        stream: _tasksStream,
        builder: (context, tasks) {
          if (tasks.hasError) return const PageFailure();
          if (!tasks.hasData) return const Center(child: LuminaProgress());
          final pending = tasks.data!;
          final focus = pending
              .where(
                (t) =>
                    (t.important == true && t.urgent == true) ||
                    (t.due != null && t.due!.compareTo(key) <= 0),
              )
              .toList();
          final deadlines =
              pending
                  .where((t) => t.due != null && t.due!.compareTo(key) > 0)
                  .toList()
                ..sort((a, b) {
                  if (a.manualPosition != null || b.manualPosition != null) {
                    final order = (a.manualPosition ?? 0x7fffffff).compareTo(
                      b.manualPosition ?? 0x7fffffff,
                    );
                    if (order != 0) return order;
                  }
                  return a.due!.compareTo(b.due!);
                });
          return StreamBuilder<List<CalendarEvent>>(
            stream: _schedulesFor(now),
            builder: (context, schedules) {
              if (schedules.hasError) return const PageFailure();
              final remaining =
                  (schedules.data ?? const <CalendarEvent>[])
                      .where((s) => DateTime.parse(s.endAt).isAfter(now))
                      .toList()
                    ..sort((a, b) => a.startAt.compareTo(b.startAt));
              final next = remaining.firstOrNull;
              final sections = <Widget>[
                OrialisSection(
                  title: '现在关注',
                  raised: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QuietLabel('${focus.length} 项'),
                      LuminaIconButton(
                        tooltip: '恢复此列表默认排序',
                        icon: const LuminaIcon(LuminaIcons.sync, size: 16),
                        onPressed: () => ref
                            .read(taskRepositoryProvider)
                            .resetTaskOrder(
                              focus.map((task) => task.id).toList(),
                            ),
                      ),
                    ],
                  ),
                  child: LuminaCompletionList(
                    empty: _empty('眼下没有需要赶的事。'),
                    children: _orderedTasks(focus, 'today:focus'),
                  ),
                ),
                OrialisSection(
                  title: '下一安排',
                  raised: true,
                  trailing: LuminaButton(
                    primary: false,
                    icon: LuminaIcon(
                      LuminaIcons.calendar,
                      size: 18,
                      color: LuminaTheme.of(context).colors.muted,
                    ),
                    onPressed: () => context.go('/calendar'),
                    child: Text(
                      '日历',
                      style: LuminaTheme.of(context).textTheme.bodyMedium
                          .copyWith(
                            color: LuminaTheme.of(context).colors.muted,
                          ),
                    ),
                  ),
                  child: next == null ? _empty('今天没有接下来的安排。') : _schedule(next),
                ),
                OrialisSection(
                  title: '最近截止',
                  raised: true,
                  trailing: LuminaIconButton(
                    tooltip: '恢复此列表默认排序',
                    icon: const LuminaIcon(LuminaIcons.sync, size: 16),
                    onPressed: () => ref
                        .read(taskRepositoryProvider)
                        .resetTaskOrder(
                          deadlines.take(3).map((task) => task.id).toList(),
                        ),
                  ),
                  child: LuminaCompletionList(
                    empty: _empty('暂无未来的截止事项。'),
                    children: _orderedTasks(
                      deadlines.take(3).toList(),
                      'today:deadlines',
                    ),
                  ),
                ),
                OrialisSection(
                  title: '今日稍后',
                  raised: true,
                  child: remaining.length < 2
                      ? _empty('稍后留白，按自己的节奏继续。')
                      : ContentStack(
                          children: [
                            for (final s in remaining.skip(1)) _schedule(s),
                          ],
                        ),
                ),
              ];
              return LayoutBuilder(
                builder: (context, constraints) {
                  final desktop =
                      ref.watch(desktopModeProvider) &&
                      LuminaNavigationInset.of(context) == 0 &&
                      constraints.maxWidth >= 840;
                  if (desktop) {
                    final theme = LuminaTheme.of(context);
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '专注当下，从容安排',
                                      style: theme.textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${focus.length} 项需要关注，今天还有 ${remaining.length} 项安排',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              LuminaButton(
                                primary: false,
                                onPressed: () => context.go('/events'),
                                icon: const LuminaIcon(
                                  LuminaIcons.tasks,
                                  size: 18,
                                ),
                                child: const Text('全部任务'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          Expanded(
                            child: Row(
                              key: const ValueKey('desktop-today-columns'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: ListView(
                                    key: const PageStorageKey(
                                      'today-focus-scroll',
                                    ),
                                    children: [
                                      sections[0],
                                      const SizedBox(height: 24),
                                      sections[2],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  flex: 2,
                                  child: ListView(
                                    key: const PageStorageKey(
                                      'today-agenda-scroll',
                                    ),
                                    children: [
                                      sections[1],
                                      const SizedBox(height: 24),
                                      sections[3],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      LuminaPageHeaderInset.of(context) + 16,
                      20,
                      24 +
                          LuminaNavigationInset.of(context) +
                          MediaQuery.paddingOf(context).bottom,
                    ),
                    children: [ContentStack(gap: 24, children: sections)],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: LuminaTheme.of(context).textTheme.bodyMedium.copyWith(
        color: LuminaTheme.of(context).colors.muted,
      ),
    ),
  );

  List<Widget> _orderedTasks(List<Task> tasks, Object group) => [
    for (final task in tasks)
      LongPressOrderable<Task>(
        key: ValueKey('order:$group:${task.id}'),
        item: task,
        group: group,
        onReorder: (dragged, target) async {
          final ordered = List<Task>.of(tasks);
          final from = ordered.indexWhere((item) => item.id == dragged.id);
          final to = ordered.indexWhere((item) => item.id == target.id);
          if (from < 0 || to < 0 || from == to) return;
          final item = ordered.removeAt(from);
          ordered.insert(to, item);
          await ref
              .read(taskRepositoryProvider)
              .reorderTasks(ordered.map((item) => item.id).toList());
        },
        feedback: SizedBox(width: 300, child: _task(task)),
        child: _task(task),
      ),
  ];

  Widget _task(Task t) => OrialisListRow(
    key: ValueKey(t.id),
    depth: LuminaSurfaceDepth.recessed,
    title: t.title,
    detail: TaskSourceLabel(task: t),
    subtitle: [
      if (t.due != null) t.due!,
      if (t.dueTime != null) t.dueTime!,
      if (t.syncStatus != 'synced') '本地已保存',
    ].join(' · '),
    trailing: LuminaCheck(
      value: t.completed,
      onChanged: (v) => ref.read(taskRepositoryProvider).complete(t, v),
    ),
    onTap: () => showTaskEditor(
      context,
      task: t,
      onSave: (d) => ref
          .read(taskRepositoryProvider)
          .updateDetails(
            t,
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
  );
  Widget _schedule(CalendarEvent s) => OrialisListRow(
    depth: LuminaSurfaceDepth.recessed,
    title: s.title,
    leading: const LuminaIcon(LuminaIcons.clock),
    subtitle: s.allDay
        ? '全天'
        : '${timeLabel(DateTime.parse(s.startAt).toLocal())} — ${timeLabel(DateTime.parse(s.endAt).toLocal())}',
    onTap: () => context.push(
      '/calendar/schedule/${Uri.encodeComponent(s.id)}?date=${dateKey(DateTime.parse(s.startAt).toLocal())}',
    ),
  );
}
