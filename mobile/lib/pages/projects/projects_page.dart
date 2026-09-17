import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
import '../../core/database/app_database.dart';
import '../../features/projects/data/project_repository.dart';

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({super.key});
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  Project? _selected;

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(projectRepositoryProvider);
    return OrialisPageScaffold(
      title: _selected == null ? '项目' : _selected!.name,
      subtitle: _selected == null ? '项目、里程碑与关联任务' : '里程碑与 Next Action',
      actions: [
        if (_selected != null)
          IconButton(
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.arrow_back),
          ),
      ],
      floatingActionButton: _selected == null
          ? FloatingActionButton.extended(
              onPressed: () => _createProject(context),
              icon: const Icon(Icons.add),
              label: const Text('新建项目'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _createMilestone(context, _selected!),
              icon: const Icon(Icons.add),
              label: const Text('新建里程碑'),
            ),
      body: _selected == null
          ? StreamBuilder<List<Project>>(
              stream: repository.watchProjects(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('加载失败：${snapshot.error}'));
                }
                final projects = snapshot.data ?? const [];
                if (projects.isEmpty) {
                  return const OrialisEmptyState(text: '还没有项目。', card: false);
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.page),
                  itemCount: projects.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => Card(
                    child: ListTile(
                      title: Text(projects[index].name),
                      subtitle: Text(projects[index].goal ?? '暂无目标'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'edit') {
                            await _editProject(context, projects[index]);
                          }
                          if (action == 'delete') {
                            await repository.deleteProject(projects[index]);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => setState(() => _selected = projects[index]),
                    ),
                  ),
                );
              },
            )
          : _ProjectDetail(project: _selected!, repository: repository),
    );
  }

  Future<void> _createProject(BuildContext context) async {
    final result = await _textDialog(context, '新建项目', '项目名称');
    if (result != null && result.trim().isNotEmpty) {
      await ref
          .read(projectRepositoryProvider)
          .createProject(name: result.trim());
    }
  }

  Future<void> _createMilestone(BuildContext context, Project project) async {
    final result = await _textDialog(context, '新建里程碑', '里程碑名称');
    if (result != null && result.trim().isNotEmpty) {
      await ref
          .read(projectRepositoryProvider)
          .createMilestone(projectId: project.id, title: result.trim());
    }
  }

  Future<String?> _textDialog(
    BuildContext context,
    String title,
    String label,
  ) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _editProject(BuildContext context, Project project) async {
    final name = TextEditingController(text: project.name);
    final goal = TextEditingController(text: project.goal ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑项目'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: goal,
              decoration: const InputDecoration(labelText: '目标'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save == true && name.text.trim().isNotEmpty) {
      await ref
          .read(projectRepositoryProvider)
          .updateProject(
            project,
            name: name.text,
            goal: goal.text.trim().isEmpty ? null : goal.text.trim(),
          );
    }
    name.dispose();
    goal.dispose();
  }
}

class _ProjectDetail extends StatelessWidget {
  const _ProjectDetail({required this.project, required this.repository});
  final Project project;
  final ProjectRepository repository;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpacing.page),
    children: [
      Text(project.goal ?? '暂无项目目标'),
      const SizedBox(height: AppSpacing.section),
      const Text('里程碑', style: TextStyle(fontWeight: FontWeight.bold)),
      StreamBuilder<List<ProjectMilestone>>(
        stream: repository.watchMilestones(project.id),
        builder: (context, snapshot) {
          final milestones = snapshot.data ?? const [];
          if (milestones.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('暂无里程碑'),
            );
          }
          return Column(
            children: [
              for (final milestone in milestones)
                ListTile(
                  leading: Checkbox(
                    value: milestone.completed,
                    onChanged: (value) =>
                        repository.completeMilestone(milestone, value ?? false),
                  ),
                  title: Text(milestone.title),
                  subtitle: Text(milestone.due ?? '无截止日期'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'delete') {
                        await repository.deleteMilestone(milestone);
                      }
                      if (action == 'edit') {
                        if (!context.mounted) return;
                        await _editMilestone(context, repository, milestone);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      const SizedBox(height: AppSpacing.section),
      const Text(
        '关联任务 / Next Action',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      StreamBuilder<List<Task>>(
        stream: repository.watchProjectTasks(project.id),
        builder: (context, snapshot) {
          final tasks = (snapshot.data ?? const [])
              .where((task) => !task.completed)
              .toList();
          final nextAction = selectNextAction(project, tasks);
          if (tasks.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('暂无未完成关联任务'),
            );
          }
          return Column(
            children: [
              if (nextAction != null)
                ListTile(
                  title: const Text('Next Action'),
                  subtitle: Text(nextAction.title),
                ),
              for (final task in tasks)
                ListTile(
                  title: Text(task.title),
                  subtitle: Text(task.due ?? '无截止日期'),
                ),
            ],
          );
        },
      ),
    ],
  );
}

Future<void> _editMilestone(
  BuildContext context,
  ProjectRepository repository,
  ProjectMilestone milestone,
) async {
  final title = TextEditingController(text: milestone.title);
  final due = TextEditingController(text: milestone.due ?? '');
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('编辑里程碑'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          TextField(
            controller: due,
            decoration: const InputDecoration(labelText: '截止日期'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (save == true && title.text.trim().isNotEmpty) {
    await repository.updateMilestone(
      milestone,
      title: title.text,
      due: due.text.trim().isEmpty ? null : due.text.trim(),
    );
  }
  title.dispose();
  due.dispose();
}
