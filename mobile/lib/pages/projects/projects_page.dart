import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory, OrialisPageScaffold;

import '../../core/database/app_database.dart';
import '../../features/categories/item_category.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/long_press_orderable.dart';
import '../shared/page_parts.dart';
import '../shared/adaptive_layout.dart';

/// Maps the stored project status onto the product wording.
String _projectStatusLabel(String status) => switch (status) {
  'not_started' => '未开始',
  'completed' => '已完成',
  'archived' => '已归档',
  _ => '进行中',
};

bool _matchesProjectStatus(Project project, String? statusFilter) =>
    statusFilter == null || project.status == statusFilter;

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({
    this.embedded = false,
    this.active = true,
    this.topInset = 0,
    this.statusFilter,
    super.key,
  });
  final bool embedded;
  final bool active;
  final double topInset;
  final String? statusFilter;
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  String? _selected = LuminaCardMemory.selectedProject;
  bool _showCompletedMilestones = false;
  ProjectRepository? _streamRepository;
  Stream<List<Project>>? _projectsStream;
  final Map<String, Stream<List<ProjectMilestone>>> _milestoneStreams = {};
  final Map<String, Stream<List<Task>>> _taskStreams = {};

  void _useRepository(ProjectRepository repository) {
    if (identical(_streamRepository, repository)) return;
    _streamRepository = repository;
    _projectsStream = repository.watchProjects();
    _showCompletedMilestones = false;
    _milestoneStreams.clear();
    _taskStreams.clear();
  }

  Stream<List<ProjectMilestone>> _watchMilestones(String projectId) =>
      _milestoneStreams.putIfAbsent(
        projectId,
        () => _streamRepository!.watchMilestones(projectId),
      );

  Stream<List<Task>> _watchProjectTasks(String projectId) =>
      _taskStreams.putIfAbsent(
        projectId,
        () => _streamRepository!.watchProjectTasks(projectId),
      );

  Future<void> _editProject([Project? project]) async {
    await showLuminaSheet<void>(
      context: context,
      builder: (_) => _ProjectEditor(
        title: project == null ? '新建项目' : '编辑项目',
        project: project,
        onSave: (draft) async {
          final r = ref.read(projectRepositoryProvider);
          if (project == null) {
            await r.createProject(
              name: draft.name,
              goal: draft.goal,
              category: draft.category,
              status: draft.status ?? 'not_started',
              description: draft.description,
              startDate: draft.startDate,
              due: draft.due,
            );
          } else {
            await r.updateProject(
              project,
              name: draft.name,
              goal: draft.goal,
              category: draft.category,
              status: draft.status,
              description: Value(draft.description),
              startDate: Value(draft.startDate),
              due: Value(draft.due),
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
    setState(() {
      if (_selected != p.id) _showCompletedMilestones = false;
      _selected = p.id;
    });
    LuminaCardMemory.selectProject(p.id);
  }

  void _closeProject() {
    setState(() {
      _selected = null;
      _showCompletedMilestones = false;
    });
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
    _useRepository(ref.watch(projectRepositoryProvider));
    final body = StreamBuilder<List<Project>>(
      key: ObjectKey(_streamRepository!),
      stream: _projectsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const PageFailure();
        if (!snapshot.hasData) return const Center(child: LuminaProgress());
        final projects = snapshot.data!
            .where(
              (project) => _matchesProjectStatus(project, widget.statusFilter),
            )
            .toList(growable: false);
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
                if ((desktop ||
                        (OrialisAdaptiveLayout.maybeOf(context)?.wide ??
                            false)) &&
                    constraints.maxWidth >= 720 &&
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '把想法，逐步实现',
                                  style: LuminaTheme.of(context)
                                      .textTheme
                                      .titleLarge,
                                ),
                                const SizedBox(height: 4),
                                QuietLabel(_projectListScopeLabel()),
                              ],
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
                      LuminaEmptyState(
                        text: widget.statusFilter == null
                            ? '为一个稍长的目标建立项目，再拆成可完成的里程碑。'
                            : '这个状态还没有项目。再点顶栏当前状态即可查看全部。',
                      ),
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
                                  QuietLabel(p.goal ?? '还没有设置目标'),
                                  _projectBadges(p),
                                  StreamBuilder<List<ProjectMilestone>>(
                                    stream: _watchMilestones(p.id),
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
                    QuietLabel(
                      '${_projectListScopeLabel()} · ${projects.length} 个',
                    ),
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
                            Expanded(
                              child: QuietLabel(_projectListScopeLabel()),
                            ),
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
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: QuietLabel(
                                  widget.statusFilter == null
                                      ? '新建一个项目，把目标拆成具体步骤。'
                                      : '这个状态还没有项目。',
                                ),
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
                                            _projectBadges(project),
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
                                        ? widget.statusFilter == null
                                              ? '建立项目，再用里程碑和关联事件把想法变成进展。'
                                              : '切换顶部状态，或再次点按当前状态查看全部。'
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
                                          _projectBadges(selected),
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

  String _projectListScopeLabel() => widget.statusFilter == null
      ? '全部项目 · 点按右侧当前状态可取消筛选'
      : '${_projectStatusLabel(widget.statusFilter!)}项目 · 再次点按可查看全部';

  Widget _projectBadges(Project project) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      KeyedSubtree(
        key: ValueKey('project-status-${project.id}'),
        child: _ProjectStatusBadge(status: project.status),
      ),
      KeyedSubtree(
        key: ValueKey('project-category-${project.id}'),
        child: CategoryBadge(value: project.category),
      ),
    ],
  );

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
        stream: _watchMilestones(project.id),
        builder: (_, snapshot) {
          if (snapshot.hasError) return const PageFailure();
          final milestones = snapshot.data ?? const <ProjectMilestone>[];
          final pending = milestones.where((m) => !m.completed).toList();
          final completed = milestones.where((m) => m.completed).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending.isNotEmpty || completed.isEmpty)
                LuminaCompletionList(
                  empty: const QuietLabel('还没有里程碑。'),
                  children: [
                    for (final m in pending) _milestoneRow(project, m),
                  ],
                ),
              if (completed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Semantics(
                  expanded: _showCompletedMilestones,
                  child: LuminaListRow(
                    key: const ValueKey('completed-milestones-toggle'),
                    title: '已完成 · ${completed.length}',
                    trailing: LuminaIcon(
                      _showCompletedMilestones
                          ? LuminaIcons.chevronDown
                          : LuminaIcons.chevronRight,
                    ),
                    onTap: () => setState(
                      () =>
                          _showCompletedMilestones = !_showCompletedMilestones,
                    ),
                  ),
                ),
                LuminaReveal(
                  visible: _showCompletedMilestones,
                  child: LuminaCompletionList(
                    children: [
                      for (final m in completed) _milestoneRow(project, m),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
      const LuminaEngravedDivider(),
      const LuminaSectionHeader(title: '关联事件'),
      StreamBuilder<List<Task>>(
        stream: _watchProjectTasks(project.id),
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

  Widget _milestoneRow(Project project, ProjectMilestone milestone) =>
      LuminaListRow(
        key: ValueKey(milestone.id),
        depth: LuminaSurfaceDepth.recessed,
        title: milestone.title,
        subtitle: milestone.due ?? '无截止日期',
        leading: LuminaCheck(
          value: milestone.completed,
          onChanged: (value) async {
            await ref
                .read(projectRepositoryProvider)
                .completeMilestone(milestone, value);
            if (value && mounted) {
              setState(() => _showCompletedMilestones = false);
            }
          },
        ),
        trailing: LuminaIconButton(
          tooltip: '管理里程碑',
          icon: const LuminaIcon(LuminaIcons.more),
          onPressed: () async {
            final action = await chooseRecordAction(context);
            if (!mounted) return;
            if (action == 'edit') await _milestone(project, milestone);
            if (action == 'delete' &&
                mounted &&
                await confirmDelete(context, milestone.title)) {
              await ref
                  .read(projectRepositoryProvider)
                  .deleteMilestone(milestone);
            }
          },
        ),
        onTap: () => _milestone(project, milestone),
      );
}

class _ProjectStatusBadge extends StatelessWidget {
  const _ProjectStatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final color = switch (status) {
      'not_started' => theme.colors.muted,
      'completed' => theme.colors.accent,
      'archived' => theme.colors.outline,
      _ => theme.colors.accent,
    };
    return LuminaSurface(
      color: color.withValues(alpha: .13),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      radius: LuminaRadius.attachment,
      child: Text(
        _projectStatusLabel(status),
        style: theme.textTheme.labelSmall.copyWith(color: color),
      ),
    );
  }
}

class _ProjectDraft {
  const _ProjectDraft({
    required this.name,
    required this.goal,
    required this.category,
    required this.status,
    required this.description,
    required this.startDate,
    required this.due,
  });

  final String name;
  final String? goal;
  final String category;
  final String? status;
  final String? description;
  final String? startDate;
  final String? due;
}

class _ProjectEditor extends StatefulWidget {
  const _ProjectEditor({
    required this.title,
    required this.project,
    required this.onSave,
  });

  final String title;
  final Project? project;
  final Future<void> Function(_ProjectDraft draft) onSave;

  @override
  State<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<_ProjectEditor> {
  late final _name = TextEditingController(text: widget.project?.name);
  late final _goal = TextEditingController(text: widget.project?.goal);
  late final _description = TextEditingController(
    text: widget.project?.description,
  );
  late String _category =
      widget.project?.category ?? ItemCategory.general.value;
  late String? _status = switch (widget.project?.status) {
    'not_started' || 'active' || 'completed' => widget.project!.status,
    _ => widget.project == null ? 'not_started' : null,
  };
  late String? _startDate = widget.project?.startDate;
  late String? _due = widget.project?.due;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = DateTime.tryParse((start ? _startDate : _due) ?? '');
    final selected = await showLuminaDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (start) {
        _startDate = dateKey(selected);
      } else {
        _due = dateKey(selected);
      }
    });
  }

  Widget _dateRow({required bool start}) {
    final value = start ? _startDate : _due;
    return LuminaListRow(
      key: ValueKey(
        start ? 'project-editor-start-date' : 'project-editor-due-date',
      ),
      title: start ? '开始日期' : '截止日期',
      subtitle: value ?? '未设置',
      onTap: () => _pickDate(start: start),
      trailing: value == null
          ? null
          : LuminaIconButton(
              tooltip: '清除${start ? '开始日期' : '截止日期'}',
              icon: const LuminaIcon(LuminaIcons.close, size: 18),
              onPressed: () => setState(() {
                if (start) {
                  _startDate = null;
                } else {
                  _due = null;
                }
              }),
            ),
    );
  }

  String? _optional(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  @override
  Widget build(BuildContext context) => ContentStack(
    gap: 16,
    children: [
      Text(widget.title, style: LuminaTheme.of(context).textTheme.titleLarge),
      LuminaTextField(
        key: const ValueKey('project-editor-name'),
        controller: _name,
        label: '名称',
        autofocus: true,
      ),
      LuminaTextField(
        key: const ValueKey('project-editor-goal'),
        controller: _goal,
        label: '目标',
        maxLines: 2,
      ),
      KeyedSubtree(
        key: const ValueKey('project-editor-category'),
        child: CategoryField(
          value: _category,
          onChanged: (value) => setState(() => _category = value),
        ),
      ),
      if (_status != null)
        LuminaSegmented<String>(
          key: const ValueKey('project-editor-status'),
          transparent: true,
          items: const {
            'not_started': '未开始',
            'active': '进行中',
            'completed': '已完成',
          },
          value: _status!,
          onChanged: (value) => setState(() => _status = value),
        )
      else
        const QuietLabel('这是旧归档项目；保存时保留归档状态。'),
      _dateRow(start: true),
      _dateRow(start: false),
      LuminaTextField(
        key: const ValueKey('project-editor-description'),
        controller: _description,
        label: '描述',
        maxLines: 3,
      ),
      if (_error != null) Text(_error!),
      LuminaButton(
        key: const ValueKey('project-editor-save'),
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
                  await widget.onSave(
                    _ProjectDraft(
                      name: _name.text.trim(),
                      goal: _optional(_goal),
                      category: _category,
                      status: _status,
                      description: _optional(_description),
                      startDate: _startDate,
                      due: _due,
                    ),
                  );
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
