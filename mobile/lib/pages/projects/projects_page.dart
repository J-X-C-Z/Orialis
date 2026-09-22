import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/events/presentation/task_editor.dart';
import '../shared/page_parts.dart';

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({this.embedded = false, super.key});
  final bool embedded;
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  String? _selected;
  Future<void> _editProject([Project? project]) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (_) => _NameEditor(
        title: project == null ? '新建项目' : '编辑项目',
        name: project?.name,
        detail: project?.goal,
        onSave: (name, detail) async {
          final r = ref.read(projectRepositoryProvider);
          if (project == null) {
            await r.createProject(
              name: name,
              goal: detail.isEmpty ? null : detail,
            );
          } else {
            await r.updateProject(
              project,
              name: name,
              goal: detail.isEmpty ? null : detail,
            );
          }
        },
      ),
    );
  }

  Future<void> _milestone(
    Project project, [
    ProjectMilestone? milestone,
  ]) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (_) => _NameEditor(
        title: milestone == null ? '新增里程碑' : '编辑里程碑',
        name: milestone?.title,
        detail: milestone?.due,
        date: true,
        onSave: (title, due) async {
          final r = ref.read(projectRepositoryProvider);
          if (milestone == null) {
            await r.createMilestone(
              projectId: project.id,
              title: title,
              due: due.isEmpty ? null : due,
            );
          } else {
            await r.updateMilestone(
              milestone,
              title: title,
              due: due.isEmpty ? null : due,
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = StreamBuilder<List<Project>>(
      stream: ref.watch(projectRepositoryProvider).watchProjects(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const PageFailure();
        if (!snapshot.hasData) return const Center(child: LuminaProgress());
        final projects = snapshot.data!;
        final selected = projects.where((p) => p.id == _selected).firstOrNull;
        return PopScope(
          canPop: selected == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _selected = null);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              ContentStack(
                gap: 20,
                children: [
                  Row(
                    children: [
                      if (selected != null) ...[
                        LuminaIconButton(
                          tooltip: '返回项目',
                          icon: const LuminaIcon(LuminaIcons.back),
                          onPressed: () => setState(() => _selected = null),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(
                          selected?.name ?? '把想法，逐步实现',
                          style: LuminaTheme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      LuminaIconButton(
                        tooltip: selected == null ? '新建项目' : '新增里程碑',
                        icon: const LuminaIcon(LuminaIcons.add),
                        onPressed: () => selected == null
                            ? _editProject()
                            : _milestone(selected),
                      ),
                    ],
                  ),
                  if (selected == null) ...[
                    if (projects.isEmpty)
                      const OrialisEmptyState(text: '为一个稍长的目标建立项目，再拆成可完成的里程碑。'),
                    for (final p in projects)
                      LuminaSurface(
                        onTap: () => setState(() => _selected = p.id),
                        child: ContentStack(
                          children: [
                            Row(
                              children: [
                                const LuminaIcon(LuminaIcons.folder),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    p.name,
                                    style: LuminaTheme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                LuminaIconButton(
                                  tooltip: '管理 ${p.name}',
                                  icon: const LuminaIcon(LuminaIcons.more),
                                  onPressed: () async {
                                    final action = await chooseRecordAction(
                                      context,
                                    );
                                    if (!mounted) return;
                                    if (action == 'edit') await _editProject(p);
                                    if (action == 'delete' &&
                                        context.mounted &&
                                        await confirmDelete(context, p.name)) {
                                      await ref
                                          .read(projectRepositoryProvider)
                                          .deleteProject(p);
                                    }
                                  },
                                ),
                              ],
                            ),
                            QuietLabel(p.goal ?? '还没有设置目标'),
                            StreamBuilder<List<ProjectMilestone>>(
                              stream: ref
                                  .watch(projectRepositoryProvider)
                                  .watchMilestones(p.id),
                              builder: (_, s) {
                                final items =
                                    s.data ?? const <ProjectMilestone>[];
                                final next = items
                                    .where((m) => !m.completed)
                                    .firstOrNull;
                                return ContentStack(
                                  gap: 6,
                                  children: [
                                    QuietLabel(
                                      '${items.where((m) => m.completed).length} / ${items.length} 里程碑',
                                    ),
                                    Text(
                                      next == null
                                          ? (items.isEmpty
                                                ? '下一步：添加里程碑'
                                                : '全部里程碑已完成')
                                          : '下一步：${next.title}',
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                  ] else ...[
                    if (selected.goal != null) QuietLabel(selected.goal!),
                    OrialisSection(
                      title: '里程碑',
                      child: StreamBuilder<List<ProjectMilestone>>(
                        stream: ref
                            .watch(projectRepositoryProvider)
                            .watchMilestones(selected.id),
                        builder: (_, snapshot) {
                          if (snapshot.hasError) return const PageFailure();
                          final milestones =
                              snapshot.data ?? const <ProjectMilestone>[];
                          return ContentStack(
                            children: [
                              if (milestones.isEmpty)
                                const QuietLabel('还没有里程碑。'),
                              for (final m in milestones)
                                OrialisListRow(
                                  title: m.title,
                                  subtitle: m.due ?? '无截止日期',
                                  leading: LuminaCheck(
                                    value: m.completed,
                                    onChanged: (v) => ref
                                        .read(projectRepositoryProvider)
                                        .completeMilestone(m, v),
                                  ),
                                  trailing: LuminaIconButton(
                                    tooltip: '管理里程碑',
                                    icon: const LuminaIcon(LuminaIcons.more),
                                    onPressed: () async {
                                      final a = await chooseRecordAction(
                                        context,
                                      );
                                      if (!mounted) return;
                                      if (a == 'edit') {
                                        await _milestone(selected, m);
                                      }
                                      if (a == 'delete' &&
                                          context.mounted &&
                                          await confirmDelete(
                                            context,
                                            m.title,
                                          )) {
                                        await ref
                                            .read(projectRepositoryProvider)
                                            .deleteMilestone(m);
                                      }
                                    },
                                  ),
                                  onTap: () => _milestone(selected, m),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    OrialisSection(
                      title: '关联事件',
                      child: StreamBuilder<List<Task>>(
                        stream: ref
                            .watch(projectRepositoryProvider)
                            .watchProjectTasks(selected.id),
                        builder: (_, s) {
                          if (s.hasError) return const PageFailure();
                          final tasks = s.data ?? const <Task>[];
                          final next = selectNextAction(selected, tasks);
                          return ContentStack(
                            children: [
                              if (tasks.isEmpty)
                                const QuietLabel('在事件编辑中选择此项目，即可建立关联。'),
                              if (next != null)
                                QuietLabel('下一行动 · ${next.title}'),
                              for (final t in tasks)
                                OrialisListRow(
                                  title: t.title,
                                  subtitle: t.due ?? '无截止日期',
                                  trailing: LuminaCheck(
                                    value: t.completed,
                                    onChanged: (v) => ref
                                        .read(taskRepositoryProvider)
                                        .complete(t, v),
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
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
    return widget.embedded
        ? body
        : OrialisPageScaffold(
            title: '项目',
            padding: EdgeInsets.zero,
            body: body,
          );
  }
}

class _NameEditor extends StatefulWidget {
  const _NameEditor({
    required this.title,
    required this.onSave,
    this.name,
    this.detail,
    this.date = false,
  });
  final String title;
  final Future<void> Function(String name, String detail) onSave;
  final String? name, detail;
  final bool date;
  @override
  State<_NameEditor> createState() => _NameEditorState();
}

class _NameEditorState extends State<_NameEditor> {
  late final _name = TextEditingController(text: widget.name);
  late final _detail = TextEditingController(text: widget.detail);
  String? _error;
  bool _saving = false;
  @override
  void dispose() {
    _name.dispose();
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ContentStack(
    gap: 16,
    children: [
      Text(widget.title, style: LuminaTheme.of(context).textTheme.titleLarge),
      LuminaTextField(controller: _name, label: '名称', autofocus: true),
      if (widget.date)
        OrialisListRow(
          title: '截止日期',
          subtitle: _detail.text.isEmpty ? '未设置' : _detail.text,
          onTap: () async {
            final d = await showLuminaDatePicker(
              context: context,
              initialDate: DateTime.tryParse(_detail.text) ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (d != null && mounted) setState(() => _detail.text = dateKey(d));
          },
          trailing: LuminaIconButton(
            tooltip: '清除日期',
            icon: const LuminaIcon(LuminaIcons.close),
            onPressed: () => setState(_detail.clear),
          ),
        )
      else
        LuminaTextField(controller: _detail, label: '目标', maxLines: 3),
      if (_error != null) Text(_error!),
      LuminaButton(
        onPressed: _saving
            ? null
            : () async {
                if (_name.text.trim().isEmpty) {
                  setState(() => _error = '请填写名称。');
                  return;
                }
                setState(() {
                  _saving = true;
                  _error = null;
                });
                try {
                  await widget.onSave(_name.text.trim(), _detail.text.trim());
                  if (context.mounted) Navigator.pop(context);
                } catch (_) {
                  if (mounted)
                    setState(() {
                      _saving = false;
                      _error = '保存失败，内容已保留，请重试。';
                    });
                }
              },
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
  );
}
