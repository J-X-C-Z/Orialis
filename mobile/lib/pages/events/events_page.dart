import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';

class EventsPage extends ConsumerWidget {
  const EventsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(eventRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('事件')),
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
            return const Center(child: Text('还没有事件，先记录一件要做的事。'));
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
                      repository.completeTask(task, value ?? false),
                  title: Text(task.title),
                  subtitle: Text(
                    task.due == null
                        ? '无截止日期'
                        : '${task.due}${task.dueTime == null ? '' : ' ${task.dueTime}'}',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'edit') {
                        await _editTask(context, ref, task);
                      }
                      if (action == 'delete') {
                        await repository.deleteTask(task);
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
    var draft = '';
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增事件'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => draft = value,
          decoration: const InputDecoration(labelText: '标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title != null && title.trim().isNotEmpty) {
      await ref.read(eventRepositoryProvider).createTask(title: title);
    }
  }

  Future<void> _editTask(BuildContext context, WidgetRef ref, Task task) async {
    var draft = task.title;
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑事件'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => draft = value,
          decoration: InputDecoration(labelText: '标题', hintText: task.title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title != null && title.trim().isNotEmpty) {
      await ref.read(eventRepositoryProvider).updateTask(task, title: title);
    }
  }
}
