import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
import '../../core/database/app_database.dart';

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taskRepository = ref.watch(taskRepositoryProvider);
    final scheduleRepository = ref.watch(scheduleRepositoryProvider);
    final today = DateTime.now();
    final todayKey =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    return OrialisPageScaffold(
      title: 'Orialis',
      subtitle: _dateLabel(today),
      padding: EdgeInsets.zero,
      body: StreamBuilder(
        stream: taskRepository.watchTasks(),
        builder: (context, snapshot) {
          final allTasks = snapshot.data ?? const [];
          final tasks = allTasks
              .where((task) => task.due == todayKey && !task.completed)
              .toList();
          final overdue = allTasks
              .where(
                (task) =>
                    !task.completed &&
                    task.due != null &&
                    task.due!.compareTo(todayKey) < 0,
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              8,
              AppSpacing.page,
              32,
            ),
            children: [
              Text('今天', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                '先看今天真正需要关注的事。',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 8),
              Text('未完成 ${tasks.length + overdue.length} 项 · 日程见下方'),
              const SizedBox(height: AppSpacing.section),
              _TodaySection(
                title: '到期事项',
                description: '这里是任务，只关注今天需要完成的内容。',
                child: tasks.isEmpty
                    ? const _EmptyState()
                    : Column(
                        children: [
                          for (final task in tasks) _TaskTile(task: task),
                        ],
                      ),
              ),
              if (overdue.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.section),
                _TodaySection(
                  title: '逾期未完成',
                  description: '这些任务不会被静默归入今天，但仍需要处理。',
                  child: Column(
                    children: [
                      for (final task in overdue) _TaskTile(task: task),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.section),
              StreamBuilder(
                stream: scheduleRepository.watchForDate(today),
                builder: (context, eventSnapshot) {
                  final events = eventSnapshot.data ?? const [];
                  return _TodaySection(
                    title: '今日安排',
                    description: '这里是日程，只展示今天已经安排的时间段。',
                    child: events.isEmpty
                        ? const _EmptyState(text: '今天没有已安排的时间段。')
                        : Column(
                            children: [
                              for (final event in events)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.schedule),
                                  title: Text(event.title),
                                  subtitle: Text(
                                    '${_time(event.startAt)}–${_time(event.endAt)}',
                                  ),
                                ),
                            ],
                          ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _dateLabel(DateTime date) => '${date.month}月${date.day}日';
  String _time(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _TodaySection extends StatelessWidget {
  const _TodaySection({
    required this.title,
    required this.description,
    required this.child,
  });
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OrialisSectionHeader(title: title),
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.item),
        child: Text(
          description,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
      ),
      child,
    ],
  );
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});
  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: CheckboxListTile(
      value: task.completed,
      onChanged: (value) =>
          ref.read(taskRepositoryProvider).complete(task, value ?? false),
      title: Text(task.title),
      subtitle: task.dueTime == null ? null : Text(task.dueTime!),
      controlAffinity: ListTileControlAffinity.leading,
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.text = '今天没有到期事项。'});
  final String text;
  @override
  Widget build(BuildContext context) => OrialisEmptyState(text: text);
}
