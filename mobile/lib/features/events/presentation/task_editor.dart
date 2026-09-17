import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../data/event_repository.dart';

enum TriStateChoice { unset, no, yes }

bool? triStateValue(TriStateChoice choice) => switch (choice) {
  TriStateChoice.unset => null,
  TriStateChoice.no => false,
  TriStateChoice.yes => true,
};

TriStateChoice triStateChoice(bool? value) => switch (value) {
  null => TriStateChoice.unset,
  false => TriStateChoice.no,
  true => TriStateChoice.yes,
};

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
  final String? notes;
  final String? due;
  final String? dueTime;
  final bool? important;
  final bool? urgent;
  final int? reminderMinutes;
  final TaskRecurrence? recurrence;
  final String? projectId;
}

Future<void> showTaskEditor(
  BuildContext context, {
  required Future<void> Function(TaskEditorDraft draft) onSave,
  Task? task,
}) async {
  final title = TextEditingController(text: task?.title ?? '');
  final notes = TextEditingController(text: task?.notes ?? '');
  final due = TextEditingController(text: task?.due ?? '');
  final dueTime = TextEditingController(text: task?.dueTime ?? '');
  final project = TextEditingController(text: task?.projectId ?? '');
  final reminder = TextEditingController(
    text: task?.reminderMinutes?.toString() ?? '',
  );
  var important = triStateChoice(task?.important);
  var urgent = triStateChoice(task?.urgent);
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(task == null ? '新增事件' : '编辑事件'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                TextField(
                  controller: due,
                  decoration: const InputDecoration(
                    labelText: '截止日期 YYYY-MM-DD',
                  ),
                ),
                TextField(
                  controller: dueTime,
                  decoration: const InputDecoration(labelText: '时间 HH:mm'),
                ),
                TextField(
                  controller: project,
                  decoration: const InputDecoration(labelText: 'Project ID'),
                ),
                TextField(
                  controller: reminder,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '提醒分钟'),
                ),
                _TriStateField(
                  label: '重要',
                  value: important,
                  onChanged: (v) => setState(() => important = v),
                ),
                _TriStateField(
                  label: '紧急',
                  value: urgent,
                  onChanged: (v) => setState(() => urgent = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final value = title.text.trim();
                if (value.isEmpty) return;
                await onSave(
                  TaskEditorDraft(
                    title: value,
                    notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
                    due: due.text.trim().isEmpty ? null : due.text.trim(),
                    dueTime: dueTime.text.trim().isEmpty
                        ? null
                        : dueTime.text.trim(),
                    important: triStateValue(important),
                    urgent: triStateValue(urgent),
                    reminderMinutes: int.tryParse(reminder.text.trim()),
                    recurrence: task == null
                        ? null
                        : TaskRecurrence.decode(task.recurrence),
                    projectId: project.text.trim().isEmpty
                        ? null
                        : project.text.trim(),
                  ),
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  } finally {
    title.dispose();
    notes.dispose();
    due.dispose();
    dueTime.dispose();
    project.dispose();
    reminder.dispose();
  }
}

class _TriStateField extends StatelessWidget {
  const _TriStateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final TriStateChoice value;
  final ValueChanged<TriStateChoice> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<TriStateChoice>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: const [
      DropdownMenuItem(value: TriStateChoice.unset, child: Text('未设置')),
      DropdownMenuItem(value: TriStateChoice.no, child: Text('否')),
      DropdownMenuItem(value: TriStateChoice.yes, child: Text('是')),
    ],
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}
