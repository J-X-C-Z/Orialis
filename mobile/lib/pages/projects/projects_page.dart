import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/events/presentation/task_editor.dart';
import '../shared/page_parts.dart';
import '../shell/orialis_shell.dart';

/// Maps the stored project status onto the product wording.
String _projectStatusLabel(String status) => switch (status) {
  'completed' => '已完成',
  'archived' => '已归档',
  _ => '进行中',
};

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({this.embedded = false, super.key});
  final bool embedded;
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  String? _selected = LuminaCardMemory.selectedProject;
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

  final _scroll = ScrollController();
  void _openProject(Project p) {
    setState(() => _selected = p.id);
    LuminaCardMemory.selectProject(p.id);
  }

  void _closeProject() {
    setState(() => _selected = null);
    LuminaCardMemory.selectProject(null);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
        if (MediaQuery.sizeOf(context).width >=
            OrialisShell.desktopBreakpoint) {
          return _desktopProjects(projects, selected);
        }
        return PopScope(
          canPop: selected == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeProject();
          },
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              24 +
                  LuminaNavigationInset.of(context) +
                  MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '把想法，逐步实现',
                        style: LuminaTheme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    LuminaIconButton(
                      tooltip: '新建项目',
                      icon: const LuminaIcon(LuminaIcons.add),
                      onPressed: () => _editProject(),
                    ),
                  ],
                ),
              ),
              if (projects.isEmpty)
                const OrialisEmptyState(text: '为一个稍长的目标建立项目，再拆成可完成的里程碑。'),
              for (final p in projects)
                LuminaReveal(
                  key: ValueKey(p.id),
                  visible: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: LuminaExpandableCard(
                      expanded: selected?.id == p.id,
                      onExpand: () => _openProject(p),
                      header: LuminaCardHeader(
                        title: p.name,
                        expanded: selected?.id == p.id,
                        onTitleTap: () => selected?.id == p.id
                            ? _closeProject()
                            : _openProject(p),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                      ),
                      summary: LuminaStack(
                        gap: 6,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: QuietLabel(
                                  p.goal ?? '还没有设置目标',
                                ),
                              ),
                              QuietLabel(_projectStatusLabel(p.status)),
                            ],
                          ),
                          StreamBuilder<List<ProjectMilestone>>(
                            stream: ref
                                .watch(projectRepositoryProvider)
                                .watchMilestones(p.id),
                            builder: (_, snapshot) {
                              final items =
                                  snapshot.data ?? const <ProjectMilestone>[];
                              final next = items
                                  .where((m) => !m.completed)
                                  .firstOrNull;
                              return LuminaStack(
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
                      detailBuilder: (_) => _details(p),
                    ),
                  ),
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

  Widget _desktopProjects(List<Project> projects, Project? selected) {
    final colors = LuminaTheme.of(context).colors;
    return Row(
      children: [
        SizedBox(
          width: 336,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 16),
            child: LuminaSurface(
              depth: LuminaSurfaceDepth.raised,
              radius: 28,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 4, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '项目',
                            style: LuminaTheme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        LuminaIconButton(
                          tooltip: '新建项目',
                          icon: const LuminaIcon(LuminaIcons.add),
                          onPressed: () => _editProject(),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: projects.isEmpty
                        ? const OrialisEmptyState(
                            text: '还没有项目。',
                            card: false,
                          )
                        : ListView.separated(
                            itemCount: projects.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final project = projects[index];
                              return OrialisListRow(
                                title: project.name,
                                subtitle: project.goal ?? '还没有设置目标',
                                selected: selected?.id == project.id,
                                onTap: () => _openProject(project),
                                trailing: LuminaIconButton(
                                  tooltip: '管理 ${project.name}',
                                  icon: const LuminaIcon(LuminaIcons.more),
                                  onPressed: () async {
                                    final action = await chooseRecordAction(
                                      context,
                                    );
                                    if (!mounted) return;
                                    if (action == 'edit') {
                                      await _editProject(project);
                                    }
                                    if (action == 'delete' &&
                                        context.mounted &&
                                        await confirmDelete(
                                          context,
                                          project.name,
                                        )) {
                                      await ref
                                          .read(projectRepositoryProvider)
                                          .deleteProject(project);
                                      if (mounted &&
                                          _selected == project.id) {
                                        _closeProject();
                                      }
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Container(width: 1, color: colors.outline),
        Expanded(
          child: selected == null
              ? const OrialisEmptyState(
                  text: '从左侧选择一个项目，查看里程碑与下一行动。',
                  card: false,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  child: LuminaSurface(
                    depth: LuminaSurfaceDepth.raised,
                    radius: 28,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LuminaCardHeader(
                          title: selected.name,
                          trailing: LuminaIconButton(
                            tooltip: '管理 ${selected.name}',
                            icon: const LuminaIcon(LuminaIcons.more),
                            onPressed: () async {
                              final action = await chooseRecordAction(context);
                              if (!mounted) return;
                              if (action == 'edit') {
                                await _editProject(selected);
                              }
                              if (action == 'delete' &&
                                  context.mounted &&
                                  await confirmDelete(
                                    context,
                                    selected.name,
                                  )) {
                                await ref
                                    .read(projectRepositoryProvider)
                                    .deleteProject(selected);
                                if (mounted) _closeProject();
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        _details(selected),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _details(Project project) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (project.goal != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: QuietLabel(project.goal!),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: LuminaCardHeader(
          title: '里程碑',
          trailing: LuminaIconButton(
            tooltip: '新增里程碑',
            icon: const LuminaIcon(LuminaIcons.add),
            onPressed: () => _milestone(project),
          ),
        ),
      ),
      StreamBuilder<List<ProjectMilestone>>(
        stream: ref
            .watch(projectRepositoryProvider)
            .watchMilestones(project.id),
        builder: (_, snapshot) {
          if (snapshot.hasError) return const PageFailure();
          return LuminaCompletionList(
            empty: const QuietLabel('还没有里程碑。'),
            children: [
              for (final m in snapshot.data ?? const <ProjectMilestone>[])
                OrialisListRow(
                  key: ValueKey(m.id),
                  depth: LuminaSurfaceDepth.recessed,
                  title: m.title,
                  subtitle: m.due ?? '无截止日期',
                  leading: LuminaCheck(
                    value: m.completed,
                    onChanged: (value) => ref
                        .read(projectRepositoryProvider)
                        .completeMilestone(m, value),
                  ),
                  trailing: LuminaIconButton(
                    tooltip: '管理里程碑',
                    icon: const LuminaIcon(LuminaIcons.more),
                    onPressed: () async {
                      final action = await chooseRecordAction(context);
                      if (!mounted) return;
                      if (action == 'edit') await _milestone(project, m);
                      if (action == 'delete' &&
                          mounted &&
                          await confirmDelete(context, m.title)) {
                        await ref
                            .read(projectRepositoryProvider)
                            .deleteMilestone(m);
                      }
                    },
                  ),
                  onTap: () => _milestone(project, m),
                ),
            ],
          );
        },
      ),
      const LuminaEngravedDivider(),
      const OrialisSectionHeader(title: '关联事件'),
      StreamBuilder<List<Task>>(
        stream: ref
            .watch(projectRepositoryProvider)
            .watchProjectTasks(project.id),
        builder: (_, snapshot) {
          if (snapshot.hasError) return const PageFailure();
          final tasks = snapshot.data ?? const <Task>[];
          final next = selectNextAction(project, tasks);
          return LuminaCompletionList(
            empty: const QuietLabel('在事件编辑中选择此项目，即可建立关联。'),
            children: [
              if (next != null)
                QuietLabel(
                  '下一行动 · ${next.title}',
                  key: const ValueKey('next-action'),
                ),
              for (final t in tasks)
                OrialisListRow(
                  key: ValueKey(t.id),
                  depth: LuminaSurfaceDepth.recessed,
                  title: t.title,
                  subtitle: t.due ?? '无截止日期',
                  trailing: LuminaCheck(
                    value: t.completed,
                    onChanged: (value) =>
                        ref.read(taskRepositoryProvider).complete(t, value),
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
    ],
  );
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
                  if (mounted) {
                    setState(() {
                      _saving = false;
                      _error = '保存失败，内容已保留，请重试。';
                    });
                  }
                }
              },
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
  );
}
