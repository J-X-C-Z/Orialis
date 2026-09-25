import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
import '../../features/events/presentation/task_children.dart';
import '../../features/events/presentation/task_quadrant.dart';
import '../projects/projects_page.dart';
import '../shared/page_parts.dart';

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
    padding: EdgeInsets.zero,
    actions: [
      if (_page == 0)
        LuminaIconButton(
          tooltip: '新增事件',
          icon: const LuminaIcon(LuminaIcons.add),
          onPressed: () => _edit(),
        ),
    ],
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: LuminaSegmented<int>(
            items: const {0: '四象限', 1: '项目'},
            value: _page,
            onChanged: (v) {
              _pager.animateToPage(
                v,
                duration: MediaQuery.of(context).disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: luminaEaseOut,
              );
            },
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pager,
            onPageChanged: (v) => setState(() => _page = v),
            children: [_tasks(), const ProjectsPage(embedded: true)],
          ),
        ),
      ],
    ),
  );
  Widget _tasks() => StreamBuilder<List<Task>>(
    stream: _tasksStream,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const PageFailure();
      if (!snapshot.hasData) return const Center(child: LuminaProgress());
      final tasks = snapshot.data!
          .where(
            (t) => switch (_contentFilter) {
              'done' => t.completed,
              'undated' => !t.completed && t.due == null,
              _ => !t.completed,
            },
          )
          .toList();
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 +
              LuminaNavigationInset.of(context) +
              MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          LuminaSegmented<String>(
            items: const {'active': '待完成', 'undated': '无截止', 'done': '已完成'},
            value: _selectedFilter,
            onChanged: _selectFilter,
          ),
          const SizedBox(height: 20),
          ContentStack(
            children: [
              for (final q in const [
                TaskQuadrant.urgentImportant,
                TaskQuadrant.urgentOnly,
                TaskQuadrant.importantOnly,
                TaskQuadrant.neither,
              ])
                _quadrant(q, tasks.where((t) => quadrantOf(t) == q).toList()),
            ],
          ),
          const SizedBox(height: 16),
          LuminaReveal(
            visible:
                _holdUnclassified ||
                tasks.any((t) => quadrantOf(t) == TaskQuadrant.unclassified),
            child: _quadrant(
              TaskQuadrant.unclassified,
              tasks
                  .where((t) => quadrantOf(t) == TaskQuadrant.unclassified)
                  .toList(),
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
  Widget _quadrant(
    TaskQuadrant q,
    List<Task> tasks, {
    ValueChanged<bool>? onCompletionActivityChanged,
  }) => LuminaPalette(
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
        children: [for (final t in tasks) _task(t)],
      ),
    ),
  );
  Widget _task(Task t) => LuminaSurface(
    key: ValueKey(t.id),
    depth: LuminaSurfaceDepth.recessed,
    radius: 18,
    padding: const EdgeInsets.all(12),
    child: ContentStack(
      gap: 4,
      children: [
        if (t.parentTaskId != null || t.scheduleId != null)
          TaskSourceLabel(task: t),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LuminaTap(
                behavior: HitTestBehavior.opaque,
                onTap: () => _edit(t),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    t.title,
                    style: LuminaTheme.of(context).textTheme.recessedTitle,
                  ),
                ),
              ),
            ),
            LuminaCheck(
              value: t.completed,
              onChanged: (v) => ref.read(taskRepositoryProvider).complete(t, v),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: QuietLabel(
                t.due == null
                    ? '未设截止'
                    : '${t.due}${t.dueTime == null ? '' : ' ${t.dueTime}'}',
              ),
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
                    await confirmDelete(
                      context,
                      t.title,
                      detail: '若有子事件，将一并删除。',
                    )) {
                  if (!mounted) return;
                  await ref.read(taskRepositoryProvider).delete(t);
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}
