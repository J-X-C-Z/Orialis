import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;

import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/task_children.dart';
import '../../features/events/presentation/long_press_orderable.dart';
import '../../features/events/presentation/quick_event_button.dart';
import '../shared/due_label.dart';
import '../shared/page_parts.dart';
import '../shared/adaptive_layout.dart';

class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});
  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage>
    with WidgetsBindingObserver {
  Timer? _clock;
  bool _visible = false;
  bool _foreground = true;
  late final Stream<List<Task>> _tasksStream;
  Stream<List<CalendarEvent>>? _schedulesStream;
  String? _schedulesDay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // Hold one long-lived stream: rebuilding the page must not resubscribe
    // Drift watches every minute tick.
    _tasksStream = ref
        .read(taskRepositoryProvider)
        .watchTasksByFilters(completed: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _updateClock();
  }

  void _updateClock() {
    if (!_visible || !_foreground) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    // Hidden branches keep their state; only the visible page needs time ticks.
    _clock ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateClock();
    if (_foreground && _visible) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
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
      floatingActionButton: const QuickEventButton(),
      // Phones show the date in the overview line instead.
      actions: [
        if (ref.watch(desktopModeProvider))
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
              final neumorphic = LuminaTheme.of(context).data.neumorphic;
              final glassTitle =
                  !ref.watch(desktopModeProvider) &&
                  (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS);
              Widget paletteSection(LuminaCardPalette palette, Widget child) =>
                  neumorphic
                  ? LuminaPalette(palette: palette, child: child)
                  : child;
              final sections = <Widget>[
                paletteSection(
                  LuminaCardPalette.ocean,
                  LuminaSection(
                    title: '现在关注',
                    raised: true,
                    glassTitle: glassTitle,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QuietLabel('${focus.length} 项'),
                        if (focus.any((t) => t.manualPosition != null))
                          LuminaIconButton(
                            tooltip: '恢复此列表默认排序',
                            icon: const LuminaIcon(
                              LuminaIcons.sortReset,
                              size: 16,
                            ),
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
                ),
                paletteSection(
                  LuminaCardPalette.sage,
                  LuminaSection(
                    title: '下一安排',
                    raised: true,
                    glassTitle: glassTitle,
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
                    child: next == null
                        ? _empty('今天没有接下来的安排。')
                        : _schedule(next, now: now),
                  ),
                ),
                paletteSection(
                  LuminaCardPalette.amber,
                  LuminaSection(
                    title: '最近截止',
                    raised: true,
                    glassTitle: glassTitle,
                    trailing:
                        !deadlines.take(3).any((t) => t.manualPosition != null)
                        ? null
                        : LuminaIconButton(
                            tooltip: '恢复此列表默认排序',
                            icon: const LuminaIcon(
                              LuminaIcons.sortReset,
                              size: 16,
                            ),
                            onPressed: () => ref
                                .read(taskRepositoryProvider)
                                .resetTaskOrder(
                                  deadlines
                                      .take(3)
                                      .map((task) => task.id)
                                      .toList(),
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
                ),
                paletteSection(
                  LuminaCardPalette.lavender,
                  LuminaSection(
                    title: '今日稍后',
                    raised: true,
                    glassTitle: glassTitle,
                    child: remaining.length < 2
                        ? _empty('稍后留白，按自己的节奏继续。')
                        : ContentStack(
                            children: [
                              for (final s in remaining.skip(1)) _schedule(s),
                            ],
                          ),
                  ),
                ),
              ];
              return LayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      LuminaNavigationInset.of(context) == 0 &&
                      ((ref.watch(desktopModeProvider) &&
                              constraints.maxWidth >= 840) ||
                          ((OrialisAdaptiveLayout.maybeOf(context)?.wide ??
                                  false) &&
                              constraints.maxWidth >=
                                  560 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(14) /
                                      14));
                  if (columns) {
                    final tablet =
                        OrialisAdaptiveLayout.maybeOf(context)?.tablet ?? false;
                    // Phone landscape is short: keep the header to two lines.
                    final short = constraints.maxHeight < 520;
                    final compactColumns =
                        constraints.maxWidth < 840 && !tablet;
                    final theme = LuminaTheme.of(context);
                    return Padding(
                      padding: compactColumns
                          ? const EdgeInsets.all(12)
                          : const EdgeInsets.fromLTRB(28, 24, 28, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!short) ...[
                                      Text(
                                        _dateLine(now),
                                        style: theme.textTheme.bodySmall
                                            .copyWith(
                                              color: theme.colors.muted,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                    ],
                                    Text(
                                      '专注当下，从容安排',
                                      style: compactColumns
                                          ? theme.textTheme.titleMedium
                                          : theme.textTheme.headlineSmall,
                                    ),
                                    SizedBox(height: short ? 4 : 8),
                                    Text(
                                      short
                                          ? '${now.month}月${now.day}日 ${weekdayLabel(now)} · ${_summary(focus.length, remaining.length)}'
                                          : _summary(
                                              focus.length,
                                              remaining.length,
                                            ),
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
                          SizedBox(height: compactColumns ? 12 : 28),
                          Expanded(
                            child: Row(
                              key: const ValueKey('desktop-today-columns'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: compactColumns ? 1 : 3,
                                  child: ListView(
                                    padding: const EdgeInsets.only(bottom: 80),
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
                                SizedBox(width: compactColumns ? 12 : 24),
                                Expanded(
                                  flex: compactColumns ? 1 : 2,
                                  child: ListView(
                                    padding: const EdgeInsets.only(bottom: 80),
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
                      104 +
                          LuminaNavigationInset.of(context) +
                          MediaQuery.paddingOf(context).bottom,
                    ),
                    children: [
                      _overview(now, focus.length, remaining.length, next),
                      const SizedBox(height: 20),
                      ContentStack(gap: 24, children: sections),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  /// Date and greeting shown above both the phone overview and the wide
  /// heading, since main pages hide their title bar in landscape.
  String _dateLine(DateTime now) {
    final greeting = switch (now.hour) {
      < 5 => '夜深了',
      < 11 => '早上好',
      < 13 => '中午好',
      < 18 => '下午好',
      _ => '晚上好',
    };
    return '${now.month}月${now.day}日 ${weekdayLabel(now)} · $greeting';
  }

  String _summary(int focus, int remaining) => focus == 0 && remaining == 0
      ? '今天很清爽，没有待赶的事项和安排。'
      : [
          if (focus > 0) '$focus 项需要关注',
          if (remaining > 0) '今天还有 $remaining 项安排',
        ].join('，');

  /// Phone at-a-glance header; wide layouts use the same lines around their
  /// own heading.
  Widget _overview(
    DateTime now,
    int focus,
    int remaining,
    CalendarEvent? next,
  ) {
    final theme = LuminaTheme.of(context);
    return Semantics(
      container: true,
      header: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          key: const ValueKey('today-overview'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _dateLine(now),
              style: theme.textTheme.bodySmall.copyWith(
                color: theme.colors.muted,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _summary(focus, remaining),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: LuminaTheme.of(context).textTheme.bodyMedium
          .copyWith(color: LuminaTheme.of(context).colors.muted),
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

  Widget _task(Task t) => LuminaListRow(
    key: ValueKey(t.id),
    depth: LuminaSurfaceDepth.recessed,
    title: t.title,
    // A blank subtitle used to add an empty line under undated, synced tasks.
    detail: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (t.due != null || t.syncStatus != 'synced') ...[
          const SizedBox(height: 4),
          DueLabel(
            due: t.due,
            dueTime: t.dueTime,
            extra: [if (t.syncStatus != 'synced') '本地已保存'],
          ),
        ],
        TaskSourceLabel(task: t),
      ],
    ),
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
  Widget _schedule(CalendarEvent s, {DateTime? now}) {
    final start = DateTime.parse(s.startAt).toLocal();
    final end = DateTime.parse(s.endAt).toLocal();
    final countdown = now == null || s.allDay
        ? null
        : scheduleCountdown(start, end, now);
    return LuminaListRow(
      depth: LuminaSurfaceDepth.recessed,
      title: s.title,
      leading: const LuminaIcon(LuminaIcons.clock),
      subtitle: s.allDay ? '全天' : '${timeLabel(start)} — ${timeLabel(end)}',
      detail: countdown == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                countdown,
                style: LuminaTheme.of(context).textTheme.bodySmall.copyWith(
                  color: LuminaTheme.of(context).colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
      onTap: () => context.push(
        '/calendar/schedule/${Uri.encodeComponent(s.id)}?date=${dateKey(start)}',
      ),
    );
  }
}
