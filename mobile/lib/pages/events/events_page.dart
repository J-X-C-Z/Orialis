import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;

import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/task_quadrant.dart';
import '../../features/events/presentation/task_quadrant_sliver.dart';
import '../../features/events/presentation/long_press_orderable.dart';
import '../../features/events/presentation/quick_event_button.dart';
import '../projects/projects_page.dart';
import '../shared/page_parts.dart';
import '../shared/glass_segmented.dart';

class EventsPage extends ConsumerStatefulWidget {
  const EventsPage({super.key});
  @override
  ConsumerState<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends ConsumerState<EventsPage> {
  final _pager = PageController();
  late final Stream<List<Task>> _tasksStream;
  int _page = 0;
  static const _filterOrder = ['active', 'undated', 'done'];
  String _selectedFilter = 'active';
  String _contentFilter = 'active';
  Timer? _filterCommit;
  bool _holdUnclassified = false;
  ({Task task, bool? important, bool? urgent})? _quadrantUndo;
  @override
  void initState() {
    super.initState();
    _tasksStream = ref.read(taskRepositoryProvider).watchTasks();
  }

  @override
  void dispose() {
    _filterCommit?.cancel();
    _pager.dispose();
    super.dispose();
  }

  void _selectFilter(String target) {
    if (target == _selectedFilter) return;
    final distance =
        (_filterOrder.indexOf(target) - _filterOrder.indexOf(_selectedFilter))
            .abs();
    final deferContent =
        distance > 1 && !MediaQuery.disableAnimationsOf(context);
    _filterCommit?.cancel();
    _filterCommit = null;
    setState(() {
      _selectedFilter = target;
      if (!deferContent) _contentFilter = target;
    });
    if (deferContent) {
      // The lens may pass the middle tab, but its data must never be selected.
      // Keep the source rows until the endpoint-only row transition begins.
      _filterCommit = Timer(LuminaMotion.fast, () {
        _filterCommit = null;
        if (mounted) setState(() => _contentFilter = target);
      });
    }
  }

  Future<void> _edit([Task? task]) => showTaskEditor(
    context,
    task: task,
    onSave: (d) {
      final r = ref.read(taskRepositoryProvider);
      return task == null
          ? r.create(
              title: d.title,
              notes: d.notes,
              due: d.due,
              dueTime: d.dueTime,
              important: d.important,
              urgent: d.urgent,
              reminderMinutes: d.reminderMinutes,
              recurrence: d.recurrence,
              projectId: d.projectId,
            )
          : r.updateDetails(
              task,
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
            );
    },
  );
  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: '事件',
    subtitle: ref.watch(desktopModeProvider) ? '四象限' : null,
    padding: EdgeInsets.zero,
    floatingActionButton: const QuickEventButton(),
    actions: [
      if (_page == 0)
        LuminaIconButton(
          tooltip: '新增事件',
          icon: const LuminaIcon(LuminaIcons.add),
          onPressed: () => _edit(),
        ),
    ],
    body: ref.watch(desktopModeProvider)
        ? _tasks(20)
        : LuminaFloatingHeader(
            header: OrialisGlassSegmented<int>(
              items: const {0: '四象限', 1: '项目'},
              value: _page,
              onChanged: (v) => _pager.animateToPage(
                v,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: luminaEaseOut,
              ),
            ),
            bodyBuilder: (context, topInset) => PageView(
              controller: _pager,
              onPageChanged: (v) => setState(() => _page = v),
              children: [
                _tasks(topInset),
                Padding(
                  padding: const EdgeInsets.only(bottom: 80),
                  child: ProjectsPage(
                    embedded: true,
                    active: _page == 1,
                    topInset: topInset,
                  ),
                ),
              ],
            ),
          ),
  );
  Widget _tasks(double topInset) => StreamBuilder<List<Task>>(
    stream: _tasksStream,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const PageFailure();
      if (!snapshot.hasData) return const Center(child: LuminaProgress());
      final tasks = <Task>[];
      final grouped = {for (final q in TaskQuadrant.values) q: <Task>[]};
      for (final task in snapshot.data!) {
        final matches = switch (_contentFilter) {
          'done' => task.completed,
          'undated' => !task.completed && task.due == null,
          _ => !task.completed,
        };
        if (!matches) continue;
        tasks.add(task);
        grouped[quadrantOf(task)]!.add(task);
      }
      if (!ref.watch(desktopModeProvider)) {
        return _mobileTasks(topInset, snapshot.data!, tasks, grouped);
      }
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          topInset,
          20,
          104 +
              LuminaNavigationInset.of(context) +
              MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _taskFilters(snapshot.data!),
          const SizedBox(height: 20),
          ContentStack(
            children: [
              if (_quadrantUndo case final undo?) _undoPanel(undo),
              LayoutBuilder(
                builder: (context, constraints) {
                  const quadrants = [
                    TaskQuadrant.urgentImportant,
                    TaskQuadrant.urgentOnly,
                    TaskQuadrant.importantOnly,
                    TaskQuadrant.neither,
                  ];
                  final panels = [
                    for (final q in quadrants) _quadrant(q, grouped[q]!),
                  ];
                  if (ref.watch(desktopModeProvider) &&
                      LuminaNavigationInset.of(context) == 0 &&
                      constraints.maxWidth >= 780) {
                    return Row(
                      key: const ValueKey('desktop-task-columns'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ContentStack(
                            gap: 20,
                            children: [panels[0], panels[2]],
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: ContentStack(
                            gap: 20,
                            children: [panels[1], panels[3]],
                          ),
                        ),
                      ],
                    );
                  }
                  return ContentStack(children: panels);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          LuminaReveal(
            visible:
                _holdUnclassified ||
                grouped[TaskQuadrant.unclassified]!.isNotEmpty,
            child: _quadrant(
              TaskQuadrant.unclassified,
              grouped[TaskQuadrant.unclassified]!,
              onCompletionActivityChanged: (active) {
                if (mounted && _holdUnclassified != active) {
                  setState(() => _holdUnclassified = active);
                }
              },
            ),
          ),
          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: QuietLabel('从右上角记下一件事，再为它选择轻重缓急。'),
            ),
        ],
      );
    },
  );
  Widget _taskFilters(List<Task> allTasks) => Row(
    children: [
      Expanded(
        child: LuminaSegmented<String>(
          transparent: true,
          items: const {'active': '待完成', 'undated': '无截止', 'done': '已完成'},
          value: _selectedFilter,
          onChanged: _selectFilter,
        ),
      ),
      const SizedBox(width: 8),
      LuminaIconButton(
        tooltip: '恢复事件默认排序',
        icon: const LuminaIcon(LuminaIcons.sync),
        onPressed: () => ref
            .read(taskRepositoryProvider)
            .resetTaskOrder(allTasks.map((task) => task.id).toList()),
      ),
    ],
  );

  Widget _undoPanel(({Task task, bool? important, bool? urgent}) undo) =>
      LuminaSurface(
        glass: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Expanded(child: Text('已调整象限')),
            LuminaButton(
              primary: false,
              onPressed: () async {
                await _setTaskQuadrant(undo.task, undo.important, undo.urgent);
                if (mounted) setState(() => _quadrantUndo = null);
              },
              child: const Text('撤销'),
            ),
          ],
        ),
      );

  Widget _mobileTasks(
    double topInset,
    List<Task> allTasks,
    List<Task> tasks,
    Map<TaskQuadrant, List<Task>> grouped,
  ) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          20,
          topInset,
          20,
          104 +
              LuminaNavigationInset.of(context) +
              MediaQuery.paddingOf(context).bottom,
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(child: _taskFilters(allTasks)),
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
            if (_quadrantUndo case final undo?) ...[
              SliverToBoxAdapter(child: _undoPanel(undo)),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
            for (final q in const [
              TaskQuadrant.urgentImportant,
              TaskQuadrant.urgentOnly,
              TaskQuadrant.importantOnly,
              TaskQuadrant.neither,
            ]) ...[
              if (q != TaskQuadrant.urgentImportant)
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              _sliverQuadrant(q, grouped[q]!),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            LuminaSliverReveal(
              visible:
                  _holdUnclassified ||
                  grouped[TaskQuadrant.unclassified]!.isNotEmpty,
              sliver: _sliverQuadrant(
                TaskQuadrant.unclassified,
                grouped[TaskQuadrant.unclassified]!,
                onCompletionActivityChanged: (active) {
                  if (mounted && _holdUnclassified != active) {
                    setState(() => _holdUnclassified = active);
                  }
                },
              ),
            ),
            if (tasks.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: QuietLabel('从右上角记下一件事，再为它选择轻重缓急。'),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _sliverQuadrant(
    TaskQuadrant q,
    List<Task> tasks, {
    ValueChanged<bool>? onCompletionActivityChanged,
  }) => TaskQuadrantSliver(
    key: ValueKey(q),
    quadrant: q,
    tasks: tasks,
    onMove: (task) => _moveTaskToQuadrant(task, q),
    onCompletionActivityChanged: onCompletionActivityChanged,
    itemBuilder: (context, index) {
      final task = tasks[index];
      return LongPressOrderable<Task>(
        key: ValueKey('order:${q.name}:${task.id}'),
        item: task,
        group: q,
        onReorder: (dragged, target) => _reorderTasks(tasks, dragged, target),
        onMoveAcrossGroup: (dragged, target) => _moveTaskToQuadrant(dragged, q),
        feedback: SizedBox(width: 280, child: _task(task)),
        child: _task(task),
      );
    },
  );

  Widget _quadrant(
    TaskQuadrant q,
    List<Task> tasks, {
    ValueChanged<bool>? onCompletionActivityChanged,
  }) => DragTarget<OrderDrag<Task>>(
    onWillAcceptWithDetails: (details) => details.data.group != q,
    onAcceptWithDetails: (details) => _moveTaskToQuadrant(details.data.item, q),
    builder: (context, candidates, rejected) => LuminaPalette(
      palette: switch (q) {
        TaskQuadrant.urgentImportant => LuminaCardPalette.rose,
        TaskQuadrant.urgentOnly => LuminaCardPalette.amber,
        TaskQuadrant.importantOnly => LuminaCardPalette.ocean,
        TaskQuadrant.neither => LuminaCardPalette.sage,
        TaskQuadrant.unclassified => LuminaCardPalette.mist,
      },
      child: LuminaCollapsibleCard(
        storageId: 'quadrant:${q.name}',
        title: quadrantLabel(q),
        summary: tasks.isEmpty ? '暂无事项' : '事项已收起',
        child: LuminaCompletionList(
          key: ValueKey(q),
          empty: const QuietLabel('暂时没有事项'),
          animateChanges: true,
          onCompletionActivityChanged: onCompletionActivityChanged,
          children: [
            for (final t in tasks)
              LongPressOrderable<Task>(
                key: ValueKey('order:${q.name}:${t.id}'),
                item: t,
                group: q,
                onReorder: (dragged, target) =>
                    _reorderTasks(tasks, dragged, target),
                onMoveAcrossGroup: (dragged, target) =>
                    _moveTaskToQuadrant(dragged, q),
                feedback: SizedBox(width: 280, child: _task(t)),
                child: _task(t),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _reorderTasks(
    List<Task> current,
    Task dragged,
    Task target,
  ) async {
    final ordered = List<Task>.of(current);
    final from = ordered.indexWhere((task) => task.id == dragged.id);
    final to = ordered.indexWhere((task) => task.id == target.id);
    if (from < 0 || to < 0 || from == to) return;
    final task = ordered.removeAt(from);
    ordered.insert(to, task);
    await ref
        .read(taskRepositoryProvider)
        .reorderTasks(ordered.map((task) => task.id).toList());
  }

  Future<void> _moveTaskToQuadrant(Task task, TaskQuadrant target) async {
    final (important, urgent) = switch (target) {
      TaskQuadrant.urgentImportant => (true, true),
      TaskQuadrant.urgentOnly => (false, true),
      TaskQuadrant.importantOnly => (true, false),
      TaskQuadrant.neither => (false, false),
      TaskQuadrant.unclassified => (null, null),
    };
    try {
      final before = await ref
          .read(taskRepositoryProvider)
          .setQuadrant(task.id, important: important, urgent: urgent);
      if (mounted) {
        setState(() {
          _quadrantUndo = (
            task: before,
            important: before.important,
            urgent: before.urgent,
          );
        });
      }
    } on Object {
      if (mounted) showLuminaToast(context, '移动未能保存，请重试');
    }
  }

  Future<void> _setTaskQuadrant(
    Task task,
    bool? important,
    bool? urgent,
  ) async {
    await ref
        .read(taskRepositoryProvider)
        .setQuadrant(task.id, important: important, urgent: urgent);
  }

  Widget _task(Task t) => LuminaSurface(
    key: ValueKey(t.id),
    depth: LuminaSurfaceDepth.recessed,
    radius: 18,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: LuminaTap(
            behavior: HitTestBehavior.opaque,
            onTap: () => _edit(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: LuminaTheme.of(context).textTheme.recessedTitle,
                  ),
                  const SizedBox(height: 2),
                  QuietLabel(
                    t.due == null
                        ? '未设截止'
                        : '${t.due}${t.dueTime == null ? '' : ' ${t.dueTime}'}',
                  ),
                ],
              ),
            ),
          ),
        ),
        LuminaCheck(
          value: t.completed,
          onChanged: (v) => ref.read(taskRepositoryProvider).complete(t, v),
        ),
        LuminaIconButton(
          tooltip: '管理 ${t.title}',
          icon: const LuminaIcon(LuminaIcons.more, size: 18),
          onPressed: () async {
            final action = await chooseRecordAction(context);
            if (!mounted) return;
            if (action == 'edit') {
              await _edit(t);
              return;
            }
            if (action == 'delete' &&
                await confirmDelete(context, t.title, detail: '若有子事件，将一并删除。')) {
              if (!mounted) return;
              await ref.read(taskRepositoryProvider).delete(t);
            }
          },
        ),
      ],
    ),
  );
}
