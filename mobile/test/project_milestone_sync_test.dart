import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

const timestamp = '2026-09-17T00:00:00Z';
const deletedAt = '2026-09-18T00:00:00Z';

Map<String, dynamic> project([Map<String, dynamic> overrides = const {}]) => {
  'id': 'p1',
  'name': 'Project',
  'goal': 'Ship',
  'description': 'Description',
  'color': '#0088ff',
  'status': 'active',
  'startDate': '2026-09-17',
  'due': '2026-09-30',
  'nextActionTaskId': 't1',
  'version': 1,
  'createdAt': timestamp,
  'updatedAt': timestamp,
  ...overrides,
};

Map<String, dynamic> milestone([Map<String, dynamic> overrides = const {}]) => {
  'id': 'm1',
  'userId': 'user1',
  'projectId': 'p1',
  'title': 'Milestone',
  'due': '2026-09-25',
  'completed': false,
  'completedAt': null,
  'position': 0,
  'version': 1,
  'createdAt': timestamp,
  'updatedAt': timestamp,
  'deletedAt': null,
  ...overrides,
};

Map<String, dynamic> snapshot({int cursor = 10}) => {
  'cursor': cursor,
  'projects': [project()],
  'milestones': [
    milestone(),
    milestone({'id': 'm2', 'position': 1}),
  ],
  'tasks': [
    {
      'id': 't1',
      'title': 'Task',
      'projectId': 'p1',
      'version': 1,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'completed': false,
    },
  ],
  'calendarEvents': <Map<String, dynamic>>[],
};

Map<String, dynamic> upsert(
  int cursor,
  String type,
  Map<String, dynamic> value,
) => {
  'cursor': cursor,
  'entityType': type,
  'entityId': value['id'],
  'entityVersion': value['version'],
  'operation': 'upsert',
  'tombstone': false,
  'payloadJson': jsonEncode(value),
  'mutationId': null,
  'createdAt': timestamp,
};

Map<String, dynamic> tombstone(
  int cursor,
  String type,
  String id,
  int version,
) => {
  'cursor': cursor,
  'entityType': type,
  'entityId': id,
  'entityVersion': version,
  'operation': 'delete',
  'tombstone': true,
  'payloadJson': null,
  'mutationId': null,
  'createdAt': deletedAt,
};

Map<String, dynamic> page(List<Map<String, dynamic>> events) => {
  'events': events,
  'nextCursor': events.last['cursor'],
};

class TestConfig extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://localhost';
  @override
  Future<String> deviceId() async => 'test-device';
}

class FakeApi extends OrialisApiClient {
  FakeApi() : super(baseUrl: 'http://localhost', deviceId: 'test');

  Map<String, dynamic> snapshotResponse = snapshot();
  Map<String, dynamic>? eventResponse;
  final queuedEventResponses = <Map<String, dynamic>>[];
  int snapshotCalls = 0;
  final afterCursors = <int>[];
  bool expireNextCursor = false;

  @override
  Future<List<Map<String, dynamic>>> listConversations() async => [];
  @override
  Future<List<Map<String, dynamic>>> listMessages(
    String conversationId,
  ) async => [];
  @override
  Future<Map<String, dynamic>> syncSnapshot() async {
    snapshotCalls++;
    return snapshotResponse;
  }

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    afterCursors.add(after);
    if (expireNextCursor) {
      expireNextCursor = false;
      final request = RequestOptions(path: '/api/v1/sync/events');
      throw DioException(
        requestOptions: request,
        response: Response<void>(requestOptions: request, statusCode: 410),
      );
    }
    if (queuedEventResponses.isNotEmpty) {
      return queuedEventResponses.removeAt(0);
    }
    return eventResponse ?? {'events': [], 'nextCursor': after};
  }
}

void main() {
  late AppDatabase database;
  late SyncEngine engine;
  late FakeApi api;
  setUp(() {
    database = AppDatabase(executor: NativeDatabase.memory());
    api = FakeApi();
    engine = SyncEngine(
      database: database,
      config: TestConfig(),
      apiClient: api,
    );
  });
  tearDown(() => database.close());

  Future<String?> cursor() async => (await (database.select(
    database.syncMetadata,
  )..where((row) => row.key.equals('serverCursor'))).getSingleOrNull())?.value;
  Future<Project> storedProject() =>
      database.select(database.projects).getSingle();
  Future<ProjectMilestone> storedMilestone() => (database.select(
    database.projectMilestones,
  )..where((row) => row.id.equals('m1'))).getSingle();

  test(
    'first sync bootstraps all snapshot relationships and then pulls',
    () async {
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.snapshotCalls, 1);
      expect(api.afterCursors, [10]);
      final p = await storedProject();
      expect([p.version, p.remoteVersion, p.localRevision], [1, 1, 0]);
      expect(p.name, 'Project');
      expect(p.goal, 'Ship');
      expect(p.startDate, '2026-09-17');
      expect(p.nextActionTaskId, 't1');
      expect(p.due, '2026-09-30');
      final milestones = await database
          .watchActiveProjectMilestones(p.id)
          .first;
      expect(milestones.map((row) => row.id), ['m1', 'm2']);
      expect(milestones.map((row) => row.remoteVersion), [1, 1]);
      expect(
        (await database.select(database.tasks).getSingle()).projectId,
        p.id,
      );
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      expect(await cursor(), '10');
      await engine.applySnapshot(snapshot());
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.snapshotCalls, 1);
      expect(await database.select(database.outboxMutations).get(), isEmpty);
      expect(
        await database.select(database.projectMilestones).get(),
        hasLength(2),
      );
    },
  );

  test(
    'existing v6 cursor still requires a Project/Milestone snapshot',
    () async {
      await database
          .into(database.syncMetadata)
          .insert(
            SyncMetadataCompanion.insert(key: 'serverCursor', value: '42'),
          );
      api.snapshotResponse = snapshot(cursor: 50);
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.snapshotCalls, 1);
      expect(api.afterCursors, [50]);
      expect((await storedMilestone()).projectId, 'p1');
      expect(await cursor(), '50');
    },
  );

  test('drains every incremental page before finishing a sync pass', () async {
    api.queuedEventResponses.addAll([
      page([
        upsert(11, 'project', project({'id': 'p2', 'name': 'Second'})),
      ]),
      page([
        upsert(
          12,
          'project_milestone',
          milestone({'id': 'm3', 'projectId': 'p2'}),
        ),
      ]),
    ]);

    expect(await engine.syncOnce(), SyncState.idle);
    expect(api.afterCursors, [10, 11, 12]);
    expect(await database.select(database.projects).get(), hasLength(2));
    expect(
      (await database.select(database.projectMilestones).get()).map(
        (row) => row.id,
      ),
      contains('m3'),
    );
    expect(await cursor(), '12');
  });

  test(
    'expired cursor refreshes snapshot before resuming incremental pull',
    () async {
      await engine.applySnapshot(snapshot());
      api.expireNextCursor = true;
      api.snapshotResponse = snapshot(cursor: 20);
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.snapshotCalls, 1);
      expect(api.afterCursors, [10, 20]);
      expect(await cursor(), '20');
    },
  );

  test(
    'snapshot removes absent synced rows but preserves local creates and outbox',
    () async {
      await engine.applySnapshot(snapshot());
      await database
          .into(database.projects)
          .insert(
            ProjectsCompanion.insert(
              id: 'local',
              name: 'Offline',
              createdAt: timestamp,
              updatedAt: timestamp,
              localRevision: const Value(5),
              syncStatus: const Value('pendingCreate'),
            ),
          );
      final mutation = await OutboxStore(database).enqueue(
        entityType: 'project',
        entityId: 'local',
        operation: 'create',
        payloadJson: '{"name":"Offline"}',
        baseVersion: null,
        entityRevision: 5,
        mutationId: 'stable-id',
      );
      final replacement = snapshot(cursor: 20)
        ..['projects'] = <Map<String, dynamic>>[]
        ..['milestones'] = <Map<String, dynamic>>[]
        ..['tasks'] = <Map<String, dynamic>>[];
      await engine.applySnapshot(replacement);
      expect((await database.watchActiveProjects().first).single.id, 'local');
      expect(await database.watchActiveProjectMilestones('p1').first, isEmpty);
      expect(await database.watchActiveTasks().first, isEmpty);
      final local = await (database.select(
        database.projects,
      )..where((row) => row.id.equals('local'))).getSingle();
      expect(local.localRevision, 5);
      expect(local.syncStatus, 'pendingCreate');
      expect(
        await database.select(database.outboxMutations).getSingle(),
        mutation,
      );
      expect(await cursor(), '20');
    },
  );

  test(
    'snapshot preserves pending updates at the acknowledged server version',
    () async {
      await engine.applySnapshot(snapshot());
      await (database.update(
        database.projects,
      )..where((row) => row.id.equals('p1'))).write(
        const ProjectsCompanion(
          name: Value('Local name'),
          version: Value(2),
          localRevision: Value(4),
          syncStatus: Value('pendingUpdate'),
        ),
      );
      await (database.update(
        database.projectMilestones,
      )..where((row) => row.id.equals('m1'))).write(
        const ProjectMilestonesCompanion(
          title: Value('Local title'),
          version: Value(2),
          localRevision: Value(6),
          syncStatus: Value('pendingUpdate'),
        ),
      );
      await engine.applySnapshot(snapshot(cursor: 20));
      final p = await storedProject();
      final m = await storedMilestone();
      expect(
        [p.name, p.version, p.remoteVersion, p.localRevision, p.syncStatus],
        ['Local name', 2, 1, 4, 'pendingUpdate'],
      );
      expect(
        [m.title, m.version, m.remoteVersion, m.localRevision, m.syncStatus],
        ['Local title', 2, 1, 6, 'pendingUpdate'],
      );
      expect(await cursor(), '20');
    },
  );

  test(
    'invalid snapshot rolls back collections, cursor and initialization marker',
    () async {
      final broken = snapshot()
        ..['milestones'] = [
          milestone({'position': -1}),
        ];
      api.snapshotResponse = broken;
      expect(await engine.syncOnce(), SyncState.error);
      expect(await database.select(database.projects).get(), isEmpty);
      expect(await database.select(database.projectMilestones).get(), isEmpty);
      expect(await database.select(database.syncMetadata).get(), isEmpty);
      expect(api.afterCursors, isEmpty);
      api.snapshotResponse = snapshot();
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.snapshotCalls, 2);
    },
  );

  test(
    'incomplete and stale snapshots cannot delete data or regress cursor',
    () async {
      await engine.applySnapshot(snapshot());
      final incomplete = snapshot(cursor: 20)..remove('milestones');
      await expectLater(engine.applySnapshot(incomplete), throwsA(anything));
      await expectLater(
        engine.applySnapshot(snapshot(cursor: 9)),
        throwsFormatException,
      );
      expect(await cursor(), '10');
      expect(
        await database.select(database.projectMilestones).get(),
        hasLength(2),
      );
    },
  );

  test(
    'incremental upserts retain revisions, clear nullable fields and ignore old versions',
    () async {
      await engine.applySnapshot(snapshot());
      await database
          .update(database.projects)
          .write(const ProjectsCompanion(localRevision: Value(7)));
      await database
          .update(database.projectMilestones)
          .write(const ProjectMilestonesCompanion(localRevision: Value(8)));
      final update = page([
        upsert(
          11,
          'project',
          project({
            'version': 3,
            'name': 'Updated',
            'goal': null,
            'description': null,
            'color': null,
            'startDate': null,
            'due': null,
            'nextActionTaskId': null,
            'status': 'completed',
          }),
        ),
        upsert(
          12,
          'project_milestone',
          milestone({
            'version': 3,
            'due': null,
            'completed': true,
            'completedAt': timestamp,
            'position': 4,
          }),
        ),
      ]);
      api.eventResponse = update;
      expect(await engine.syncOnce(), SyncState.idle);
      final p = await storedProject();
      final m = await storedMilestone();
      expect([p.version, p.remoteVersion, p.localRevision], [3, 3, 7]);
      expect([
        p.goal,
        p.description,
        p.color,
        p.startDate,
        p.due,
        p.nextActionTaskId,
      ], everyElement(isNull));
      expect(p.status, 'completed');
      expect([m.version, m.remoteVersion, m.localRevision], [3, 3, 8]);
      expect(m.completedAt, timestamp);
      expect(m.completed, isTrue);
      expect(m.due, isNull);
      expect(m.position, 4);
      await engine.applySyncEvents(update);
      await engine.applySyncEvents(
        page([
          upsert(13, 'project', project({'version': 2})),
          upsert(14, 'project_milestone', milestone({'version': 2})),
        ]),
      );
      expect(await storedProject(), p);
      expect(await storedMilestone(), m);
      expect(await cursor(), '14');
      expect(await database.select(database.outboxMutations).get(), isEmpty);
    },
  );

  test(
    'milestone deletion then project cascade tombstones replay idempotently',
    () async {
      await engine.applySnapshot(snapshot());
      final deletion = page([tombstone(11, 'project_milestone', 'm1', 2)]);
      await engine.applySyncEvents(deletion);
      expect((await storedMilestone()).deletedAt, deletedAt);
      expect(
        (await database.watchActiveProjectMilestones('p1').first).single.id,
        'm2',
      );
      final cascade = page([
        tombstone(12, 'project_milestone', 'm2', 2),
        tombstone(13, 'project', 'p1', 2),
      ]);
      api.eventResponse = cascade;
      expect(await engine.syncOnce(), SyncState.idle);
      final deletedProject = await storedProject();
      final deletedMilestone = await storedMilestone();
      expect(deletedProject.deletedAt, deletedAt);
      expect([deletedProject.version, deletedProject.remoteVersion], [2, 2]);
      expect(await database.watchActiveProjects().first, isEmpty);
      expect(await database.watchActiveProjectMilestones('p1').first, isEmpty);
      await engine.applySyncEvents(deletion);
      await engine.applySyncEvents(cascade);
      await engine.applySyncEvents(
        page([
          upsert(14, 'project', project()),
          upsert(15, 'project_milestone', milestone()),
          tombstone(16, 'project_milestone', 'm1', 2),
        ]),
      );
      expect(await storedProject(), deletedProject);
      expect(await storedMilestone(), deletedMilestone);
      expect(await cursor(), '16');
      expect(
        await database.select(database.projectMilestones).get(),
        hasLength(2),
      );
    },
  );

  test('unseen tombstones prevent stale payload resurrection', () async {
    await engine.applySyncEvents(
      page([
        tombstone(1, 'project', 'p1', 3),
        tombstone(2, 'project_milestone', 'm1', 3),
      ]),
    );
    await engine.applySyncEvents(
      page([
        upsert(3, 'project', project({'version': 2})),
        upsert(4, 'project_milestone', milestone({'version': 2})),
      ]),
    );
    expect(await database.select(database.projects).get(), isEmpty);
    expect(await database.select(database.projectMilestones).get(), isEmpty);
    expect(await cursor(), '4');
  });

  test(
    'a failure midway through a page rolls back earlier writes and retries',
    () async {
      await engine.applySnapshot(snapshot());
      final update = upsert(
        11,
        'project',
        project({'version': 2, 'name': 'Updated'}),
      );
      final broken = upsert(12, 'project_milestone', milestone({'version': 2}));
      broken['payloadJson'] = '{invalid';
      api.eventResponse = page([update, broken]);
      expect(await engine.syncOnce(), SyncState.error);
      expect((await storedProject()).name, 'Project');
      expect(await cursor(), '10');
      api.eventResponse = page([
        update,
        upsert(12, 'project_milestone', milestone({'version': 2})),
      ]);
      expect(await engine.syncOnce(), SyncState.idle);
      expect((await storedProject()).name, 'Updated');
      expect((await storedMilestone()).remoteVersion, 2);
      expect(api.afterCursors, [10, 10, 12]);
      expect(await cursor(), '12');
    },
  );

  test('database write failure rolls back tombstones and cursor', () async {
    await engine.applySnapshot(snapshot());
    await database.customStatement(
      '''CREATE TRIGGER fail_milestone
      BEFORE UPDATE ON project_milestones BEGIN SELECT RAISE(ABORT, 'disk failure'); END''',
    );
    final deletion = page([
      tombstone(11, 'project', 'p1', 2),
      tombstone(12, 'project_milestone', 'm1', 2),
    ]);
    await expectLater(engine.applySyncEvents(deletion), throwsA(anything));
    expect((await storedProject()).deletedAt, isNull);
    expect(await cursor(), '10');
    final markers = await (database.select(
      database.syncMetadata,
    )..where((row) => row.key.like('remoteTombstone:%'))).get();
    expect(markers, isEmpty);
    await database.customStatement('DROP TRIGGER fail_milestone');
    await engine.applySyncEvents(deletion);
    expect((await storedMilestone()).deletedAt, deletedAt);
    expect(await cursor(), '12');
  });

  test(
    'unsupported entities and mismatched identity cannot advance cursor',
    () async {
      await engine.applySnapshot(snapshot());
      for (final invalid in [
        upsert(12, 'future_entity', project()),
        {...upsert(12, 'project', project()), 'entityId': 'different'},
        {...upsert(12, 'project', project()), 'entityVersion': 2},
        {...upsert(12, 'project', project()), 'tombstone': true},
        {...upsert(12, 'project', project()), 'operation': 'future_operation'},
      ]) {
        await expectLater(
          engine.applySyncEvents(
            page([
              upsert(11, 'project', project({'version': 2})),
              invalid,
            ]),
          ),
          throwsFormatException,
        );
        expect((await storedProject()).version, 1);
        expect(await cursor(), '10');
      }
    },
  );

  test(
    'cursor cannot jump beyond events or advance on a malformed empty page',
    () async {
      await engine.applySnapshot(snapshot());
      await expectLater(
        engine.applySyncEvents({
          'events': [
            upsert(11, 'project', project({'version': 2})),
          ],
          'nextCursor': 12,
        }),
        throwsFormatException,
      );
      await expectLater(
        engine.applySyncEvents({'events': [], 'nextCursor': 12}),
        throwsFormatException,
      );
      await expectLater(
        engine.applySyncEvents(
          page([
            upsert(12, 'project', project({'version': 2})),
            upsert(11, 'project', project({'version': 3})),
          ]),
        ),
        throwsFormatException,
      );
      expect((await storedProject()).version, 1);
      expect(await cursor(), '10');
    },
  );

  for (final type in ['project', 'project_milestone']) {
    for (final operation in ['upsert', 'delete']) {
      test(
        '$type $operation conflict retains pending edit, outbox and cursor',
        () async {
          await engine.applySnapshot(snapshot());
          final isProject = type == 'project';
          final id = isProject ? 'p1' : 'm1';
          if (isProject) {
            await database
                .update(database.projects)
                .write(
                  const ProjectsCompanion(
                    name: Value('Local'),
                    version: Value(2),
                    localRevision: Value(9),
                    syncStatus: Value('pendingUpdate'),
                  ),
                );
          } else {
            await (database.update(
              database.projectMilestones,
            )..where((row) => row.id.equals(id))).write(
              const ProjectMilestonesCompanion(
                title: Value('Local'),
                version: Value(2),
                localRevision: Value(9),
                syncStatus: Value('pendingUpdate'),
              ),
            );
          }
          final mutation = await OutboxStore(database).enqueue(
            entityType: type,
            entityId: id,
            operation: 'update',
            payloadJson: '{"name":"Local"}',
            baseVersion: 1,
            entityRevision: 9,
            mutationId: 'fixed-mutation',
          );
          api.eventResponse = page([
            operation == 'delete'
                ? tombstone(11, type, id, 2)
                : upsert(
                    11,
                    type,
                    isProject
                        ? project({'version': 2})
                        : milestone({'version': 2}),
                  ),
          ]);
          expect(await engine.syncOnce(), SyncState.conflict);
          expect(await cursor(), '10');
          expect(
            await database.select(database.outboxMutations).getSingle(),
            mutation,
          );
          if (isProject) {
            final p = await storedProject();
            expect(
              [
                p.name,
                p.version,
                p.remoteVersion,
                p.localRevision,
                p.syncStatus,
              ],
              ['Local', 2, 1, 9, 'pendingUpdate'],
            );
            expect(p.deletedAt, isNull);
          } else {
            final m = await storedMilestone();
            expect(
              [
                m.title,
                m.version,
                m.remoteVersion,
                m.localRevision,
                m.syncStatus,
              ],
              ['Local', 2, 1, 9, 'pendingUpdate'],
            );
            expect(m.deletedAt, isNull);
          }
        },
      );
    }
  }

  test(
    'snapshot conflict preserves pending edits and the old cursor',
    () async {
      await engine.applySnapshot(snapshot());
      await database
          .update(database.projectMilestones)
          .write(
            const ProjectMilestonesCompanion(
              localRevision: Value(3),
              syncStatus: Value('pendingUpdate'),
            ),
          );
      for (final remote in [
        <Map<String, dynamic>>[],
        [
          milestone({'version': 2}),
        ],
      ]) {
        await expectLater(
          engine.applySnapshot(snapshot(cursor: 20)..['milestones'] = remote),
          throwsA(anything),
        );
        expect(await cursor(), '10');
        expect((await storedMilestone()).localRevision, 3);
        expect((await storedMilestone()).remoteVersion, 1);
      }
    },
  );

  test(
    'milestone parent is immutable and completing does not create a schedule',
    () async {
      await engine.applySnapshot(snapshot());
      await expectLater(
        engine.applySyncEvents(
          page([
            upsert(
              11,
              'project_milestone',
              milestone({'version': 2, 'projectId': 'other'}),
            ),
          ]),
        ),
        throwsFormatException,
      );
      expect(await cursor(), '10');
      await engine.applySyncEvents(
        page([
          upsert(
            11,
            'project_milestone',
            milestone({
              'version': 2,
              'completed': true,
              'completedAt': timestamp,
            }),
          ),
          upsert(
            12,
            'project_milestone',
            milestone({
              'version': 3,
              'completed': false,
              'completedAt': null,
              'due': null,
            }),
          ),
        ]),
      );
      final m = await storedMilestone();
      expect(m.completed, isFalse);
      expect(m.completedAt, isNull);
      expect(m.due, isNull);
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );
}
