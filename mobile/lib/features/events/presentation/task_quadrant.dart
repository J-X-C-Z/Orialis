import '../../../core/database/app_database.dart';

enum TaskQuadrant {
  urgentImportant,
  importantOnly,
  urgentOnly,
  neither,
  unclassified,
}

TaskQuadrant quadrantOf(Task task) {
  if (task.urgent == true && task.important == true) {
    return TaskQuadrant.urgentImportant;
  }
  if (task.important == true && task.urgent == false) {
    return TaskQuadrant.importantOnly;
  }
  if (task.important == false && task.urgent == true) {
    return TaskQuadrant.urgentOnly;
  }
  if (task.important == false && task.urgent == false) {
    return TaskQuadrant.neither;
  }
  return TaskQuadrant.unclassified;
}

String quadrantLabel(TaskQuadrant quadrant) => switch (quadrant) {
  TaskQuadrant.urgentImportant => '重要且紧急',
  TaskQuadrant.importantOnly => '重要但不紧急',
  TaskQuadrant.urgentOnly => '紧急但不重要',
  TaskQuadrant.neither => '不重要且不紧急',
  TaskQuadrant.unclassified => '未分类',
};
