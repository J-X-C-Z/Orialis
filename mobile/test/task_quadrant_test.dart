import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/presentation/task_quadrant.dart';
import 'package:orialis_mobile/features/events/presentation/task_editor.dart';

Task taskWith({bool? important, bool? urgent}) => Task(
  id: 't',
  title: '任务',
  notes: null,
  due: null,
  dueTime: null,
  important: important,
  urgent: urgent,
  completed: false,
  completedAt: null,
  reminderMinutes: null,
  projectId: null,
  recurrence: null,
  version: 1,
  remoteVersion: 1,
  localRevision: 0,
  createdAt: '2026-01-01',
  updatedAt: '2026-01-01',
  deletedAt: null,
  syncStatus: 'synced',
);

void main() {
  test('quadrant preserves tri-state priority semantics', () {
    expect(
      quadrantOf(taskWith(important: true, urgent: true)),
      TaskQuadrant.urgentImportant,
    );
    expect(
      quadrantOf(taskWith(important: true, urgent: false)),
      TaskQuadrant.importantOnly,
    );
    expect(
      quadrantOf(taskWith(important: false, urgent: true)),
      TaskQuadrant.urgentOnly,
    );
    expect(
      quadrantOf(taskWith(important: false, urgent: false)),
      TaskQuadrant.neither,
    );
    expect(
      quadrantOf(taskWith(important: null, urgent: null)),
      TaskQuadrant.unclassified,
    );
    expect(quadrantLabel(TaskQuadrant.unclassified), '未分类');
  });

  test('editor tri-state and draft preserve nullable and optional fields', () {
    expect(triStateValue(TriStateChoice.unset), isNull);
    expect(triStateValue(TriStateChoice.no), false);
    expect(triStateValue(TriStateChoice.yes), true);
    const draft = TaskEditorDraft(
      title: '任务',
      notes: '备注',
      reminderMinutes: 15,
      projectId: 'project-1',
    );
    expect(draft.notes, '备注');
    expect(draft.reminderMinutes, 15);
    expect(draft.projectId, 'project-1');
    expect(draft.important, isNull);
  });
}
