import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../shared/page_parts.dart';

class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});
  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage> {
  late final Timer _clock = Timer.periodic(const Duration(minutes: 1), (_) {
    if (mounted) setState(() {});
  });
  @override
  void initState() {
    super.initState();
    _clock;
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now(), key = dateKey(DateTime.now());
    return OrialisPageScaffold(
      title: '今日',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: QuietLabel('${now.month}月${now.day}日'),
        ),
      ],
      body: StreamBuilder<List<Task>>(
        stream: ref.watch(taskRepositoryProvider).watchTasks(),
        builder: (context, tasks) {
          if (tasks.hasError) return const PageFailure();
          if (!tasks.hasData) return const Center(child: LuminaProgress());
          final pending = tasks.data!.where((t) => !t.completed).toList();
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
                ..sort((a, b) => a.due!.compareTo(b.due!));
          return StreamBuilder<List<CalendarEvent>>(
            stream: ref.watch(scheduleRepositoryProvider).watchForDate(now),
            builder: (context, schedules) {
              if (schedules.hasError) return const PageFailure();
              final remaining =
                  (schedules.data ?? const <CalendarEvent>[])
                      .where((s) => DateTime.parse(s.endAt).isAfter(now))
                      .toList()
                    ..sort((a, b) => a.startAt.compareTo(b.startAt));
              final next = remaining.firstOrNull;
              return ListView(
                children: [
                  ContentStack(
                    gap: 24,
                    children: [
                      OrialisSection(
                        title: '现在关注',
                        trailing: QuietLabel('${focus.length} 项'),
                        child: focus.isEmpty
                            ? const OrialisEmptyState(
                                text: '眼下没有需要赶的事。',
                                card: false,
                              )
                            : ContentStack(
                                children: [for (final t in focus) _task(t)],
                              ),
                      ),
                      OrialisSection(
                        title: '下一安排',
                        trailing: LuminaButton(
                          primary: false,
                          onPressed: () => context.go('/calendar'),
                          child: const Text('日历'),
                        ),
                        child: next == null
                            ? const OrialisEmptyState(
                                text: '今天没有接下来的安排。',
                                card: false,
                              )
                            : _schedule(next),
                      ),
                      OrialisSection(
                        title: '最近截止',
                        child: deadlines.isEmpty
                            ? const OrialisEmptyState(
                                text: '暂无未来的截止事项。',
                                card: false,
                              )
                            : ContentStack(
                                children: [
                                  for (final t in deadlines.take(3)) _task(t),
                                ],
                              ),
                      ),
                      OrialisSection(
                        title: '今日稍后',
                        child: remaining.length < 2
                            ? const OrialisEmptyState(
                                text: '稍后留白，按自己的节奏继续。',
                                card: false,
                              )
                            : ContentStack(
                                children: [
                                  for (final s in remaining.skip(1))
                                    _schedule(s),
                                ],
                              ),
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _task(Task t) => OrialisListRow(
    title: t.title,
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
