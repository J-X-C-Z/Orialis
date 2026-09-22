import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../core/database/app_database.dart';
import '../../features/events/presentation/task_editor.dart';
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
  int _page = 0;
  String _filter = 'active';
  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
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
                curve: Curves.easeOutCubic,
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
    stream: ref.watch(taskRepositoryProvider).watchTasks(),
    builder: (context, snapshot) {
      if (snapshot.hasError) return const PageFailure();
      if (!snapshot.hasData) return const Center(child: LuminaProgress());
      final tasks = snapshot.data!
          .where(
            (t) => switch (_filter) {
              'done' => t.completed,
              'undated' => !t.completed && t.due == null,
              _ => !t.completed,
            },
          )
          .toList();
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          LuminaSegmented<String>(
            items: const {'active': '待完成', 'undated': '无截止', 'done': '已完成'},
            value: _filter,
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              const order = [
                TaskQuadrant.urgentImportant,
                TaskQuadrant.urgentOnly,
                TaskQuadrant.importantOnly,
                TaskQuadrant.neither,
              ];
              final cards = [
                for (final q in order)
                  _quadrant(q, tasks.where((t) => quadrantOf(t) == q).toList()),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final card in cards)
                    SizedBox(
                      width:
                          constraints.maxWidth >= 340 &&
                              MediaQuery.textScalerOf(context).scale(14) < 23
                          ? (constraints.maxWidth - 12) / 2
                          : constraints.maxWidth,
                      child: card,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          if (tasks.any((t) => quadrantOf(t) == TaskQuadrant.unclassified))
            _quadrant(
              TaskQuadrant.unclassified,
              tasks
                  .where((t) => quadrantOf(t) == TaskQuadrant.unclassified)
                  .toList(),
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
  Widget _quadrant(TaskQuadrant q, List<Task> tasks) => LuminaSurface(
    padding: const EdgeInsets.all(14),
    child: ContentStack(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                quadrantLabel(q),
                style: LuminaTheme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 6),
            QuietLabel('${tasks.length}'),
          ],
        ),
        if (tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: QuietLabel('暂时没有事项'),
          ),
        for (final t in tasks) _task(t),
      ],
    ),
  );
  Widget _task(Task t) => ContentStack(
    gap: 4,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _edit(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  t.title,
                  style: LuminaTheme.of(context).textTheme.bodyMedium,
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
              if (action == 'delete' && await confirmDelete(context, t.title)) {
                if (!mounted) return;
                await ref.read(taskRepositoryProvider).delete(t);
              }
            },
          ),
        ],
      ),
    ],
  );
}
