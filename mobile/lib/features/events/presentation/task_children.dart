import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/app.dart';
import '../../../app/design/design_components.dart';
import '../../../core/database/app_database.dart';
import '../../../pages/shared/page_parts.dart';
import 'task_editor.dart';

final _sourceTasksProvider = StreamProvider.autoDispose<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchTasks(),
);
final _sourceSchedulesProvider =
    StreamProvider.autoDispose<List<CalendarEvent>>(
      (ref) => ref.watch(scheduleRepositoryProvider).watchAll(),
    );

/// The same child-task UI is used by task and calendar details.
class TaskChildrenPanel extends ConsumerStatefulWidget {
  const TaskChildrenPanel({
    this.parentTaskId,
    this.scheduleId,
    required this.parentTitle,
    super.key,
  }) : assert((parentTaskId == null) != (scheduleId == null));
  final String? parentTaskId, scheduleId;
  final String parentTitle;
  @override
  ConsumerState<TaskChildrenPanel> createState() => _TaskChildrenPanelState();
}

class _TaskChildrenPanelState extends ConsumerState<TaskChildrenPanel> {
  late final Stream<List<Task>> _children = widget.parentTaskId != null
      ? ref.read(taskRepositoryProvider).watchChildren(widget.parentTaskId!)
      : ref.read(taskRepositoryProvider).watchForSchedule(widget.scheduleId!);

  Future<void> _edit([Task? task]) => showTaskEditor(
    context,
    task: task,
    sourceLabel: widget.parentTitle,
    onSave: (draft) {
      final repository = ref.read(taskRepositoryProvider);
      if (task == null) {
        return repository.create(
          title: draft.title,
          notes: draft.notes,
          due: draft.due,
          dueTime: draft.dueTime,
          important: draft.important,
          urgent: draft.urgent,
          reminderMinutes: draft.reminderMinutes,
          projectId: draft.projectId,
          parentTaskId: widget.parentTaskId,
          scheduleId: widget.scheduleId,
        );
      }
      return repository.updateDetails(
        task,
        title: draft.title,
        notes: draft.notes,
        due: draft.due,
        dueTime: draft.dueTime,
        important: draft.important,
        urgent: draft.urgent,
        reminderMinutes: draft.reminderMinutes,
        projectId: draft.projectId,
        reminderMinutesProvided: true,
        projectIdProvided: true,
      );
    },
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Task>>(
    stream: _children,
    builder: (context, snapshot) {
      final children = snapshot.data ?? const <Task>[];
      return ContentStack(
        children: [
          LuminaCardHeader(
            title: widget.scheduleId == null ? '子事件' : '附属事件',
            trailing: LuminaIconButton(
              tooltip: '添加子事件',
              icon: const LuminaIcon(LuminaIcons.add),
              onPressed: () => _edit(),
            ),
          ),
          if (snapshot.hasError)
            const QuietLabel('暂时无法读取子事件，请稍后重试。')
          else if (!snapshot.hasData)
            const LuminaProgress()
          else
            LuminaCompletionList(
              animateChanges: true,
              empty: QuietLabel(
                widget.scheduleId == null
                    ? '把这件事拆成几个可完成的步骤。'
                    : '记录这次日程的作业、准备或后续事项。',
              ),
              children: [
                for (final task in children)
                  OrialisListRow(
                    key: ValueKey(task.id),
                    depth: LuminaSurfaceDepth.recessed,
                    title: task.title,
                    subtitle:
                        '${task.completed ? '已完成' : '待完成'} · ${task.due ?? '无截止日期'}',
                    leading: LuminaCheck(
                      value: task.completed,
                      onChanged: (value) => ref
                          .read(taskRepositoryProvider)
                          .complete(task, value),
                    ),
                    onTap: () => _edit(task),
                    trailing: LuminaIconButton(
                      tooltip: '管理子事件',
                      icon: const LuminaIcon(LuminaIcons.more),
                      onPressed: () async {
                        final action = await chooseRecordAction(context);
                        if (!mounted) return;
                        if (action == 'edit') await _edit(task);
                        if (action == 'delete' &&
                            context.mounted &&
                            await confirmDelete(context, task.title)) {
                          await ref.read(taskRepositoryProvider).delete(task);
                        }
                      },
                    ),
                  ),
              ],
            ),
          if (widget.parentTaskId != null && children.isNotEmpty)
            const QuietLabel('全部子事件完成后，父事件也会完成。'),
        ],
      );
    },
  );
}

class TaskSourceLabel extends ConsumerWidget {
  const TaskSourceLabel({required this.task, super.key});
  final Task task;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (task.parentTaskId != null) {
      final tasks = ref.watch(_sourceTasksProvider).asData?.value;
      return QuietLabel(
        '子事件 · ${tasks?.where((p) => p.id == task.parentTaskId).firstOrNull?.title ?? '关联事件'}',
      );
    }
    if (task.scheduleId != null) {
      final schedules = ref.watch(_sourceSchedulesProvider).asData?.value;
      return QuietLabel(
        '日程附属 · ${schedules?.where((p) => p.id == task.scheduleId).firstOrNull?.title ?? '关联日程'}',
      );
    }
    return const SizedBox.shrink();
  }
}
