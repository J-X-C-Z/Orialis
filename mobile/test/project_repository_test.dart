import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';

void main() {
  late AppDatabase database;
  late ProjectRepository repository;

  setUp(() {
    database = AppDatabase(executor: NativeDatabase.memory());
    repository = ProjectRepository(database);
  });

  tearDown(() => database.close());

  test('project and milestone CRUD creates durable outbox mutations', () async {
    final project = await repository.createProject(name: 'Ship', goal: 'v1');
    var mutations = await database.select(database.outboxMutations).get();
    expect(mutations.single.entityType, 'project');
    expect(mutations.single.operation, 'create');

    await repository.updateProject(project, name: 'Ship now', goal: null);
    final milestone = await repository.createMilestone(
      projectId: project.id,
      title: 'Beta',
    );
    await repository.completeMilestone(milestone, true);
    await repository.deleteMilestone(milestone);
    await repository.deleteProject(project);

    mutations = await database.select(database.outboxMutations).get();
    expect(mutations.map((row) => row.mutationId).toSet(), hasLength(2));
    expect(mutations.map((row) => row.entityType), contains('project'));
    expect(
      mutations.map((row) => row.entityType),
      contains('project_milestone'),
    );
    expect(mutations.every((row) => row.payloadJson.isNotEmpty), isTrue);
  });

  test(
    'new projects default to general and not_started in row and outbox',
    () async {
      final defaults = await repository.createProject(name: 'Defaults');
      expect(defaults.category, 'general');
      expect(defaults.status, 'not_started');

      final custom = await repository.createProject(
        name: 'Course',
        category: 'course',
        status: 'active',
        description: 'Spring term',
        startDate: '2026-02-01',
        due: '2026-06-30',
      );
      final payload = jsonDecode(
        (await (database.select(
              database.outboxMutations,
            )..where((row) => row.entityId.equals(custom.id))).getSingle())
            .payloadJson,
      ) as Map<String, dynamic>;
      expect(payload, containsPair('category', 'course'));
      expect(payload, containsPair('status', 'active'));
      expect(payload, containsPair('description', 'Spring term'));
      expect(payload, containsPair('startDate', '2026-02-01'));
      expect(payload, containsPair('due', '2026-06-30'));
    },
  );

  test(
    'project updates preserve omitted fields and allow explicit clears',
    () async {
      final project = await repository.createProject(
        name: 'Project',
        category: 'health',
        status: 'active',
        description: 'Keep',
        startDate: '2026-01-01',
        due: '2026-03-01',
      );

      await repository.updateProject(
        project,
        name: 'Project renamed',
        goal: project.goal,
      );
      var stored = await (database.select(
        database.projects,
      )..where((row) => row.id.equals(project.id))).getSingle();
      expect(stored.category, 'health');
      expect(stored.status, 'active');
      expect(stored.description, 'Keep');
      expect(stored.startDate, '2026-01-01');
      expect(stored.due, '2026-03-01');

      await repository.updateProject(
        stored,
        name: stored.name,
        goal: stored.goal,
        category: 'future_category',
        status: 'not_started',
        description: const Value(null),
      );
      stored = await (database.select(
        database.projects,
      )..where((row) => row.id.equals(project.id))).getSingle();
      expect(stored.category, 'future_category');
      expect(stored.status, 'not_started');
      expect(stored.description, isNull);
      expect(stored.startDate, '2026-01-01');
      expect(stored.due, '2026-03-01');
    },
  );

  test(
    'next action prefers explicit incomplete task then stable due order',
    () async {
      final project = await repository.createProject(name: 'Ship');
      final first = await database
          .into(database.tasks)
          .insertReturning(
            TasksCompanion.insert(
              id: 't1',
              title: 'Later',
              due: const Value('2026-10-02'),
              projectId: Value(project.id),
              createdAt: '2026-09-17T00:00:00Z',
              updatedAt: '2026-09-17T00:00:00Z',
            ),
          );
      final second = await database
          .into(database.tasks)
          .insertReturning(
            TasksCompanion.insert(
              id: 't2',
              title: 'Sooner',
              due: const Value('2026-09-20'),
              projectId: Value(project.id),
              createdAt: '2026-09-17T00:00:00Z',
              updatedAt: '2026-09-17T00:00:00Z',
            ),
          );
      expect(selectNextAction(project, [first, second])?.id, 't2');
      final explicit = project.copyWith(nextActionTaskId: const Value('t1'));
      expect(selectNextAction(explicit, [first, second])?.id, 't1');
    },
  );

  test('outbox mutation remains after database reopen seam', () async {
    final project = await repository.createProject(name: 'Persist');
    final mutation = (await (database.select(
      database.outboxMutations,
    )..limit(10)).get()).single;
    expect(mutation.entityId, project.id);
    expect(mutation.mutationId, isNotEmpty);
  });
}
