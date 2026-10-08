import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory, OrialisPageScaffold;
import '../../core/database/app_database.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/long_press_orderable.dart';
import '../shared/page_parts.dart';

/// Maps the stored project status onto the product wording.
String _projectStatusLabel(String status) => switch (status) {
  'completed' => '已完成',
  'archived' => '已归档',
  _ => '进行中',
};

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({
    this.embedded = false,
    this.active = true,
    this.topInset = 0,
    super.key,
  });
  final bool embedded;
  final bool active;
  final double topInset;
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
  final _projectListScroll = ScrollController();
  final _projectDetailScroll = ScrollController();
  void _openProject(Project p) {
    if (_selected != p.id && _projectDetailScroll.hasClients) {
      _projectDetailScroll.jumpTo(0);
    }
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
    _projectListScroll.dispose();
    _projectDetailScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ref.watch(desktopModeProvider);
    final body = StreamBuilder<List<Project>>(
      stream: ref.watch(projectRepositoryProvider).watchProjects(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const PageFailure();
        if (!snapshot.hasData) return const Center(child: LuminaProgress());
        final projects = snapshot.data!;
        final selected = projects.where((p) => p.id == _selected).firstOrNull;
        return BackButtonListener(
          onBackButtonPressed: () async {
            if (!widget.active ||
                selected == null ||
                !TickerMode.valuesOf(context).enabled ||
                ModalRoute.of(context)?.isCurrent == false ||
                (widget.embedded &&
                    Navigator.of(context, rootNavigator: true).canPop())) {
              return false;
            }
            _closeProject();
            return true;
          },
          child: PopScope(
            canPop: !widget.active || selected == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _closeProject();
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (desktop &&
                    constraints.maxWidth >= 840 &&
                    LuminaNavigationInset.of(context) == 0) {
                  return _desktopProjects(projects, selected);
                }
                return ListView(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    20,
                    4 +
                        widget.topInset +
                        (widget.embedded
                            ? 0
                            : LuminaPageHeaderInset.of(context)),
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
                              style: LuminaTheme.of(
                                context,
                              ).textTheme.titleLarge,
                            ),
                          ),
                          LuminaIconButton(
                            tooltip: '恢复项目默认排序',
                            icon: const LuminaIcon(LuminaIcons.sync),
                            onPressed: () => ref
                                .read(projectRepositoryProvider)
                                .resetProjectOrder(),
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
                      const LuminaEmptyState(text: '为一个稍长的目标建立项目，再拆成可完成的里程碑。'),
                    for (final p in projects)
                      LongPressOrderable<Project>(
                        key: ValueKey('order:projects:${p.id}'),
                        item: p,
                        group: 'projects',
                        onReorder: (dragged, target) =>
                            _reorderProjects(projects, dragged, target),
                        feedback: SizedBox(
                          width: 320,
                          child: LuminaSurface(
                            glass: true,
                            child: Text(p.name),
                          ),
                        ),
                        child: LuminaReveal(
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
                                        if (action == 'edit') {
                                          await _editProject(p);
                                        }
                                        if (action == 'delete' &&
                                            context.mounted &&
                                            await confirmDelete(
                                              context,
                                              p.name,
                                            )) {
                                          await ref
                                              .read(projectRepositoryProvider)
                                              .deleteProject(p);
                                          if (mounted && _selected == p.id) {
                                            _closeProject();
                                          }
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
                                        child: QuietLabel(p.goal ?? '还没有设置目标'),
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
                                          snapshot.data ??
                                          const <ProjectMilestone>[];
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
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    return widget.embedded
        ? body
        : OrialisPageScaffold(
            title: '项目',
            leading: desktop
                ? null
                : LuminaIconButton(
                    tooltip: '返回',
                    icon: const LuminaIcon(LuminaIcons.back),
                    onPressed: () {
                      if (_selected != null) {
                        _closeProject();
                      } else {
                        Navigator.of(context).maybePop();
                      }
                    },
                  ),
            padding: EdgeInsets.zero,
            body: body,
          );
  }

  Widget _desktopProjects(List<Project> projects, Project? selected) {
    final theme = LuminaTheme.of(context);
    return Padding(
      key: const ValueKey('desktop-projects-workspace'),
      padding: EdgeInsets.fromLTRB(
        24,
        16 +
            widget.topInset +
            (widget.embedded ? 0 : LuminaPageHeaderInset.of(context)),
        24,
        24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('项目工作区', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    QuietLabel('${projects.length} 个项目，逐步推进每一个目标'),
                  ],
                ),
              ),
              LuminaButton(
                icon: const LuminaIcon(LuminaIcons.add),
                onPressed: () => _editProject(),
                child: const Text('新建项目'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 12, bottom: 8),
                        child: Row(
                          children: [
                            const Expanded(child: QuietLabel('全部项目')),
                            LuminaIconButton(
                              tooltip: '恢复项目默认排序',
                              icon: const LuminaIcon(LuminaIcons.sync),
                              onPressed: () => ref
                                  .read(projectRepositoryProvider)
                                  .resetProjectOrder(),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: projects.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: QuietLabel('新建一个项目，把目标拆成具体步骤。'),
                              )
                            : ListView.separated(
                                key: const ValueKey('desktop-project-list'),
                                controller: _projectListScroll,
                                padding: const EdgeInsets.fromLTRB(
                                  2,
                                  2,
                                  10,
                                  16,
                                ),
                                itemCount: projects.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (_, index) {
                                  final project = projects[index];
                                  final isSelected = selected?.id == project.id;
                                  return LongPressOrderable<Project>(
                                    key: ValueKey(
                                      'order:projects:${project.id}',
                                    ),
                                    item: project,
                                    group: 'projects',
                                    onReorder: (dragged, target) =>
                                        _reorderProjects(
                                          projects,
                                          dragged,
                                          target,
                                        ),
                                    feedback: SizedBox(
                                      width: 260,
                                      child: LuminaSurface(
                                        child: Text(project.name),
                                      ),
                                    ),
                                    child: Semantics(
                                      selected: isSelected,
                                      button: true,
                                      child: LuminaSurface(
                                        key: ValueKey(
                                          'desktop-project:${project.id}',
                                        ),
                                        radius: 12,
                                        color: isSelected
                                            ? theme.colors.accentSoft
                                            : const Color(0x00000000),
                                        padding: const EdgeInsets.all(14),
                                        onTap: () => _openProject(project),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              project.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  theme.textTheme.labelMedium,
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              project.goal ?? '添加目标，规划下一步',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                            const SizedBox(height: 8),
                                            QuietLabel(
                                              _projectStatusLabel(
                                                project.status,
                                              ),
                                            ),
                                          ],
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
                const SizedBox(width: 18),
                Expanded(
                  child: LuminaSurface(
                    key: const ValueKey('desktop-project-detail'),
                    radius: 18,
                    padding: EdgeInsets.zero,
                    child: selected == null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    projects.isEmpty ? '从一个目标开始' : '选择一个项目',
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    projects.isEmpty
                                        ? '建立项目，再用里程碑和关联事件把想法变成进展。'
                                        : '在左侧选择项目，查看目标、里程碑和下一行动。',
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  20,
                                  16,
                                  16,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            selected.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleLarge,
                                          ),
                                          const SizedBox(height: 6),
                                          QuietLabel(
                                            _projectStatusLabel(
                                              selected.status,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    LuminaButton(
                                      primary: false,
                                      onPressed: () => _editProject(selected),
                                      child: const Text('编辑项目'),
                                    ),
                                    LuminaIconButton(
                                      tooltip: '管理 ${selected.name}',
                                      icon: const LuminaIcon(LuminaIcons.more),
                                      onPressed: () async {
                                        final action = await chooseRecordAction(
                                          context,
                                        );
                                        if (!mounted) return;
                                        if (action == 'edit') {
                                          await _editProject(selected);
                                        }
                                        if (action == 'delete' &&
                                            mounted &&
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
                                  ],
                                ),
                              ),
                              const LuminaEngravedDivider(),
                              Expanded(
                                child: ListView(
                                  key: ValueKey(
                                    'desktop-project-body:${selected.id}',
                                  ),
                                  controller: _projectDetailScroll,
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    8,
                                    24,
                                    24,
                                  ),
                                  children: [_details(selected)],
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reorderProjects(
    List<Project> current,
    Project dragged,
    Project target,
  ) async {
    final ordered = List<Project>.of(current);
    final from = ordered.indexWhere((project) => project.id == dragged.id);
    final to = ordered.indexWhere((project) => project.id == target.id);
    if (from < 0 || to < 0 || from == to) return;
    final project = ordered.removeAt(from);
    ordered.insert(to, project);
    await ref
        .read(projectRepositoryProvider)
        .reorderProjects(ordered.map((project) => project.id).toList());
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
                LuminaListRow(
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
      const LuminaSectionHeader(title: '关联事件'),
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
                LuminaListRow(
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
        LuminaListRow(
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
