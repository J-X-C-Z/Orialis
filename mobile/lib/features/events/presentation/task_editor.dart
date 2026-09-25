import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/app.dart';
import '../../../app/design/design_components.dart';
import '../../../core/database/app_database.dart';
import '../../../pages/shared/page_parts.dart';
import '../data/event_repository.dart';
import 'task_children.dart';

enum TriStateChoice { unset, no, yes }

bool? triStateValue(TriStateChoice c) => switch (c) {
  TriStateChoice.unset => null,
  TriStateChoice.no => false,
  TriStateChoice.yes => true,
};
TriStateChoice triStateChoice(bool? v) => v == null
    ? TriStateChoice.unset
    : v
    ? TriStateChoice.yes
    : TriStateChoice.no;

class TaskEditorDraft {
  const TaskEditorDraft({
    required this.title,
    this.notes,
    this.due,
    this.dueTime,
    this.important,
    this.urgent,
    this.reminderMinutes,
    this.recurrence,
    this.projectId,
  });
  final String title;
  final String? notes, due, dueTime, projectId;
  final bool? important, urgent;
  final int? reminderMinutes;
  final TaskRecurrence? recurrence;
}

Future<void> showTaskEditor(
  BuildContext context, {
  required Future<void> Function(TaskEditorDraft) onSave,
  Task? task,
  String? sourceLabel,
}) => showLuminaSheet<void>(
  context: context,
  builder: (_) =>
      _TaskEditor(task: task, onSave: onSave, sourceLabel: sourceLabel),
);

class _TaskEditor extends ConsumerStatefulWidget {
  const _TaskEditor({required this.onSave, this.task, this.sourceLabel});
  final Task? task;
  final String? sourceLabel;
  final Future<void> Function(TaskEditorDraft) onSave;
  @override
  ConsumerState<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<_TaskEditor> {
  late final _title = TextEditingController(text: widget.task?.title ?? '');
  late final _notes = TextEditingController(text: widget.task?.notes ?? '');
  late final _reminder = TextEditingController(
    text: widget.task?.reminderMinutes?.toString() ?? '',
  );
  late DateTime? _due = DateTime.tryParse(widget.task?.due ?? '');
  late String? _time = widget.task?.dueTime;
  late String? _project = widget.task?.projectId;
  late TriStateChoice _important = triStateChoice(widget.task?.important);
  late TriStateChoice _urgent = triStateChoice(widget.task?.urgent);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _reminder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final minutes = int.tryParse(_reminder.text.trim());
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '请填写事件标题。');
      return;
    }
    if (_reminder.text.trim().isNotEmpty && (minutes == null || minutes < 0)) {
      setState(() => _error = '提醒请输入不小于 0 的分钟数。');
      return;
    }
    if (_time != null && _due == null) {
      setState(() => _error = '设置时间前，请先选择截止日期。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        TaskEditorDraft(
          title: _title.text.trim(),
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          due: _due == null ? null : dateKey(_due!),
          dueTime: _time,
          important: triStateValue(_important),
          urgent: triStateValue(_urgent),
          projectId: _project,
          reminderMinutes: minutes,
          recurrence: TaskRecurrence.decode(widget.task?.recurrence),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，内容已保留，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ContentStack(
    gap: 16,
    children: [
      Text(
        widget.task == null ? '新增事件' : '编辑事件',
        style: LuminaTheme.of(context).textTheme.titleLarge,
      ),
      if (widget.sourceLabel != null)
        QuietLabel('所属 · ${widget.sourceLabel}')
      else if (widget.task != null)
        TaskSourceLabel(task: widget.task!),
      LuminaTextField(
        controller: _title,
        label: '标题',
        autofocus: widget.task == null,
      ),
      LuminaTextField(controller: _notes, label: '备注', maxLines: 3),
      const QuietLabel('重要程度'),
      LuminaSegmented<TriStateChoice>(
        items: const {
          TriStateChoice.unset: '未分类',
          TriStateChoice.no: '不重要',
          TriStateChoice.yes: '重要',
        },
        value: _important,
        onChanged: (v) => setState(() => _important = v),
      ),
      const QuietLabel('紧急程度'),
      LuminaSegmented<TriStateChoice>(
        items: const {
          TriStateChoice.unset: '未分类',
          TriStateChoice.no: '不紧急',
          TriStateChoice.yes: '紧急',
        },
        value: _urgent,
        onChanged: (v) => setState(() => _urgent = v),
      ),
      OrialisListRow(
        title: '截止日期',
        subtitle: _due == null ? '未设置' : dateKey(_due!),
        trailing: _due == null
            ? null
            : LuminaIconButton(
                tooltip: '清除日期',
                icon: const LuminaIcon(LuminaIcons.close),
                onPressed: () => setState(() {
                  _due = null;
                  _time = null;
                }),
              ),
        onTap: () async {
          final d = await showLuminaDatePicker(
            context: context,
            initialDate: _due ?? DateTime.now(),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (d != null && mounted) setState(() => _due = d);
        },
      ),
      OrialisListRow(
        title: '截止时间',
        subtitle: _time ?? '未设置',
        trailing: _time == null
            ? null
            : LuminaIconButton(
                tooltip: '清除时间',
                icon: const LuminaIcon(LuminaIcons.close),
                onPressed: () => setState(() => _time = null),
              ),
        onTap: () async {
          final d = await showLuminaTimePicker(
            context: context,
            initialTime: DateTime.now(),
          );
          if (d != null && mounted) setState(() => _time = timeLabel(d));
        },
      ),
      StreamBuilder<List<Project>>(
        stream: ref.watch(projectRepositoryProvider).watchProjects(),
        builder: (context, snapshot) {
          final projects = snapshot.data ?? const <Project>[];
          return OrialisListRow(
            title: '所属项目',
            subtitle: _project == null
                ? '无'
                : projects
                          .where((p) => p.id == _project)
                          .map((p) => p.name)
                          .firstOrNull ??
                      '已关联项目',
            onTap: () async {
              final choice = await showLuminaSheet<String>(
                context: context,
                builder: (context) => ContentStack(
                  children: [
                    LuminaButton(
                      primary: false,
                      onPressed: () => Navigator.pop(context, ''),
                      child: const Text('无项目'),
                    ),
                    for (final p in projects)
                      LuminaButton(
                        primary: false,
                        onPressed: () => Navigator.pop(context, p.id),
                        child: Text(p.name),
                      ),
                  ],
                ),
              );
              if (choice != null && mounted) {
                setState(() => _project = choice.isEmpty ? null : choice);
              }
            },
          );
        },
      ),
      LuminaTextField(
        controller: _reminder,
        label: '提前提醒（分钟，可留空）',
        keyboardType: TextInputType.number,
      ),
      if (widget.task != null &&
          widget.task!.parentTaskId == null &&
          widget.task!.scheduleId == null) ...[
        const LuminaEngravedDivider(),
        TaskChildrenPanel(
          parentTaskId: widget.task!.id,
          parentTitle: widget.task!.title,
        ),
      ],
      if (_error != null)
        Text(_error!, style: const TextStyle(color: AppColors.danger)),
      Row(
        children: [
          Expanded(
            child: LuminaButton(
              primary: false,
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LuminaButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    ],
  );
}
