import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/task_quadrant.dart';

class EventsPage extends ConsumerWidget {
  const EventsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(taskRepositoryProvider);
    return OrialisPageScaffold(
      title: '事件',
      subtitle: '任务清单 · 只管理要完成的事',
      padding: EdgeInsets.zero,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createTask(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
      ),
      body: StreamBuilder(
        stream: repository.watchTasks(),
        builder: (context, snapshot) {
          final tasks = snapshot.data ?? const [];
          if (tasks.isEmpty) {
            return const OrialisEmptyState(
              text: '还没有事件，先记录一件要做的事。',
              card: false,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              8,
              AppSpacing.page,
              96,
            ),
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final task = tasks[index];
              return Card(
                child: CheckboxListTile(
                  value: task.completed,
                  onChanged: (value) =>
                      repository.complete(task, value ?? false),
                  title: Text(task.title),
                  subtitle: Text(
                    '${quadrantLabel(quadrantOf(task))} · ${task.due == null ? '无截止日期' : '${task.due}${task.dueTime == null ? '' : ' ${task.dueTime}'}'}',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'edit') {
                        await _editTask(context, ref, task);
                      }
                      if (action == 'delete') {
                        await repository.delete(task);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _createTask(BuildContext context, WidgetRef ref) async {
    await showTaskEditor(
      context,
      onSave: (draft) => ref
          .read(taskRepositoryProvider)
          .create(
            title: draft.title,
            notes: draft.notes,
            due: draft.due,
            dueTime: draft.dueTime,
            important: draft.important,
            urgent: draft.urgent,
            reminderMinutes: draft.reminderMinutes,
            recurrence: draft.recurrence,
            projectId: draft.projectId,
          ),
    );
  }

  Future<void> _editTask(BuildContext context, WidgetRef ref, Task task) async {
    await showTaskEditor(
      context,
      task: task,
      onSave: (draft) => ref
          .read(taskRepositoryProvider)
          .updateDetails(
            task,
            title: draft.title,
            notes: draft.notes,
            due: draft.due,
            dueTime: draft.dueTime,
            important: draft.important,
            urgent: draft.urgent,
            reminderMinutes: draft.reminderMinutes,
            recurrence: draft.recurrence,
            projectId: draft.projectId,
            reminderMinutesProvided: true,
            recurrenceProvided: true,
            projectIdProvided: true,
          ),
    );
  }
}
