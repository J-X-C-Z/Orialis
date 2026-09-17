import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/sync/outbox_store.dart';

Task? selectNextAction(Project project, Iterable<Task> tasks) {
  final incomplete = tasks.where((task) => !task.completed).toList();
  if (project.nextActionTaskId != null) {
    for (final task in incomplete) {
      if (task.id == project.nextActionTaskId) return task;
    }
  }
  incomplete.sort((a, b) {
    final due = (a.due == null ? 1 : 0).compareTo(b.due == null ? 1 : 0);
    if (due != 0) return due;
    final date = (a.due ?? '').compareTo(b.due ?? '');
    return date != 0 ? date : a.id.compareTo(b.id);
  });
  return incomplete.isEmpty ? null : incomplete.first;
}

class ProjectRepository {
  ProjectRepository(this.database);
  final AppDatabase database;

  Stream<List<Project>> watchProjects() => database.watchActiveProjects();

  Stream<List<ProjectMilestone>> watchMilestones(String projectId) =>
      database.watchActiveProjectMilestones(projectId);

  Stream<List<Task>> watchProjectTasks(String projectId) =>
      (database.select(database.tasks)
            ..where(
              (row) => row.projectId.equals(projectId) & row.deletedAt.isNull(),
            )
            ..orderBy([(row) => OrderingTerm(expression: row.due)]))
          .watch();

  Future<Project> createProject({required String name, String? goal}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v7();
    await database
        .into(database.projects)
        .insert(
          ProjectsCompanion.insert(
            id: id,
            name: name.trim(),
            goal: Value(goal),
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('pendingCreate'),
          ),
        );
    final project = await (database.select(
      database.projects,
    )..where((row) => row.id.equals(id))).getSingle();
    await _enqueueProject(project);
    return project;
  }

  Future<void> updateProject(
    Project project, {
    required String name,
    String? goal,
  }) async {
    await (database.update(
      database.projects,
    )..where((row) => row.id.equals(project.id))).write(
      ProjectsCompanion(
        name: Value(name.trim()),
        goal: Value(goal),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(project.localRevision + 1),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
    await _enqueueProject(await _project(project.id));
  }

  Future<void> deleteProject(Project project) async {
    await (database.update(
      database.projects,
    )..where((row) => row.id.equals(project.id))).write(
      ProjectsCompanion(
        deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(project.localRevision + 1),
        syncStatus: const Value('pendingDelete'),
      ),
    );
    await _enqueueProject(await _project(project.id));
  }

  Future<ProjectMilestone> createMilestone({
    required String projectId,
    required String title,
    String? due,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v7();
    await database
        .into(database.projectMilestones)
        .insert(
          ProjectMilestonesCompanion.insert(
            id: id,
            projectId: projectId,
            title: title.trim(),
            due: Value(due),
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('pendingCreate'),
          ),
        );
    final milestone = await (database.select(
      database.projectMilestones,
    )..where((row) => row.id.equals(id))).getSingle();
    await _enqueueMilestone(milestone);
    return milestone;
  }

  Future<void> updateMilestone(
    ProjectMilestone milestone, {
    required String title,
    String? due,
  }) async {
    await (database.update(
      database.projectMilestones,
    )..where((row) => row.id.equals(milestone.id))).write(
      ProjectMilestonesCompanion(
        title: Value(title.trim()),
        due: Value(due),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(milestone.localRevision + 1),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
    await _enqueueMilestone(await _milestone(milestone.id));
  }

  Future<void> completeMilestone(
    ProjectMilestone milestone,
    bool completed,
  ) async {
    await (database.update(
      database.projectMilestones,
    )..where((row) => row.id.equals(milestone.id))).write(
      ProjectMilestonesCompanion(
        completed: Value(completed),
        completedAt: Value(
          completed ? DateTime.now().toUtc().toIso8601String() : null,
        ),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(milestone.localRevision + 1),
        syncStatus: const Value('pendingUpdate'),
      ),
    );
    await _enqueueMilestone(await _milestone(milestone.id));
  }

  Future<void> deleteMilestone(ProjectMilestone milestone) async {
    await (database.update(
      database.projectMilestones,
    )..where((row) => row.id.equals(milestone.id))).write(
      ProjectMilestonesCompanion(
        deletedAt: Value(DateTime.now().toUtc().toIso8601String()),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
        localRevision: Value(milestone.localRevision + 1),
        syncStatus: const Value('pendingDelete'),
      ),
    );
    await _enqueueMilestone(await _milestone(milestone.id));
  }

  Future<Project> _project(String id) => (database.select(
    database.projects,
  )..where((row) => row.id.equals(id))).getSingle();
  Future<ProjectMilestone> _milestone(String id) => (database.select(
    database.projectMilestones,
  )..where((row) => row.id.equals(id))).getSingle();

  Future<void> _enqueueProject(Project project) => OutboxStore(database)
      .enqueue(
        entityType: 'project',
        entityId: project.id,
        operation: _operation(project.syncStatus),
        payloadJson: jsonEncode({
          'id': project.id,
          'name': project.name,
          'goal': project.goal,
          'description': project.description,
          'color': project.color,
          'status': project.status,
          'startDate': project.startDate,
          'due': project.due,
          'nextActionTaskId': project.nextActionTaskId,
          'version': project.version,
          'createdAt': project.createdAt,
          'updatedAt': project.updatedAt,
          'deletedAt': project.deletedAt,
        }),
        baseVersion:
            project.syncStatus == 'pendingUpdate' ||
                project.syncStatus == 'pendingDelete'
            ? project.remoteVersion
            : null,
        entityRevision: project.localRevision,
      )
      .then((_) {});

  Future<void> _enqueueMilestone(ProjectMilestone milestone) =>
      OutboxStore(database)
          .enqueue(
            entityType: 'project_milestone',
            entityId: milestone.id,
            operation: _operation(milestone.syncStatus),
            payloadJson: jsonEncode({
              'id': milestone.id,
              'projectId': milestone.projectId,
              'title': milestone.title,
              'due': milestone.due,
              'completed': milestone.completed,
              'completedAt': milestone.completedAt,
              'position': milestone.position,
              'version': milestone.version,
              'createdAt': milestone.createdAt,
              'updatedAt': milestone.updatedAt,
              'deletedAt': milestone.deletedAt,
            }),
            baseVersion:
                milestone.syncStatus == 'pendingUpdate' ||
                    milestone.syncStatus == 'pendingDelete'
                ? milestone.remoteVersion
                : null,
            entityRevision: milestone.localRevision,
          )
          .then((_) {});

  String _operation(String status) => switch (status) {
    'pendingCreate' => 'create',
    'pendingDelete' => 'delete',
    _ => 'update',
  };
}
