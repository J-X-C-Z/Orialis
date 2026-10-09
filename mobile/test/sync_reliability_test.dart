import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';

import 'project_milestone_sync_test.dart' as fixture;

class GatedApi extends fixture.FakeApi {
  final started = Completer<void>();
  final release = Completer<void>();
  final ids = <String>[];
  final bases = <Object?>[];
  bool gated = true;
  Future<Map<String, dynamic>> respond(
    Map<String, dynamic> payload,
    String id,
  ) async {
    ids.add(id);
    bases.add(payload['baseVersion']);
    if (gated) {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return {...payload, 'version': 7};
  }

  @override
  Future<Map<String, dynamic>> updateProject(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) => respond(payload, mutationId);
  @override
  Future<Map<String, dynamic>> updateProjectMilestone(
    String projectId,
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) => respond(payload, mutationId);
}

class ExpiredApi extends fixture.FakeApi {
  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    afterCursors.add(after);
    final request = RequestOptions(path: '/sync/events');
    throw DioException(
      requestOptions: request,
      response: Response<void>(requestOptions: request, statusCode: 410),
    );
  }
}

void main() {
  for (final entity in ['project', 'project_milestone']) {
    for (final operation in ['create', 'update', 'delete']) {
      test('$entity $operation rolls entity back if enqueue fails', () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final engine = SyncEngine(
          database: db,
          config: fixture.TestConfig(),
          apiClient: fixture.FakeApi(),
          includeChat: false,
        );
        await engine.applySnapshot(fixture.snapshot());
        final repository = ProjectRepository(db);
        final p = await db.select(db.projects).getSingle();
        final m = (await db.select(db.projectMilestones).get()).first;
        final beforeProjects = await db.select(db.projects).get();
        final beforeMilestones = await db.select(db.projectMilestones).get();
        await db.customStatement(
          "CREATE TRIGGER fail_enqueue BEFORE INSERT ON outbox_mutations BEGIN SELECT RAISE(ABORT, 'enqueue failed'); END",
        );
        Future<Object?> write() async {
          if (entity == 'project') {
            if (operation == 'create') {
              return repository.createProject(name: 'new');
            }
            if (operation == 'update') {
              await repository.updateProject(p, name: 'new');
              return null;
            }
            await repository.deleteProject(p);
          } else {
            if (operation == 'create') {
              return repository.createMilestone(projectId: p.id, title: 'new');
            }
            if (operation == 'update') {
              await repository.updateMilestone(m, title: 'new');
              return null;
            }
            await repository.deleteMilestone(m);
          }
          return null;
        }

        await expectLater(write(), throwsA(anything));
        expect(await db.select(db.projects).get(), beforeProjects);
        expect(await db.select(db.projectMilestones).get(), beforeMilestones);
        expect(await db.select(db.outboxMutations).get(), isEmpty);
      });
    }
    test(
      '$entity legacy ACK replays accepted mutation without inventing identity',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final api = GatedApi()..gated = false;
        final engine = SyncEngine(
          database: db,
          config: fixture.TestConfig(),
          apiClient: api,
          includeChat: false,
        );
        await engine.applySnapshot(fixture.snapshot());
        final repository = ProjectRepository(db);
        if (entity == 'project') {
          await repository.updateProject(
            await db.select(db.projects).getSingle(),
            name: 'legacy',
          );
        } else {
          await repository.updateMilestone(
            (await db.select(db.projectMilestones).get()).first,
            title: 'legacy',
          );
        }
        final original = await db.select(db.outboxMutations).getSingle();
        final outbox = OutboxStore(db);
        await outbox.markInFlight(original.mutationId);
        await outbox.acknowledge(original.mutationId);
        expect(await engine.syncOnce(), SyncState.idle);
        expect(api.ids, [original.mutationId]);
        expect(
          (await db.select(db.outboxMutations).get()).single.mutationId,
          original.mutationId,
        );
        expect(await engine.syncOnce(), SyncState.idle);
        expect(api.ids, [original.mutationId]);
      },
    );
    test('$entity ACK failure reopens and retries the same mutation', () async {
      final dir = await Directory.systemTemp.createTemp('ori106-ack-');
      addTearDown(() => dir.delete(recursive: true));
      AppDatabase open() =>
          AppDatabase(executor: NativeDatabase(File('${dir.path}/db.sqlite')));
      var db = open();
      addTearDown(() => db.close());
      final api = GatedApi()..gated = false;
      SyncEngine engine() => SyncEngine(
        database: db,
        config: fixture.TestConfig(),
        apiClient: api,
        includeChat: false,
      );
      await engine().applySnapshot(fixture.snapshot());
      final repository = ProjectRepository(db);
      if (entity == 'project') {
        await repository.updateProject(
          await db.select(db.projects).getSingle(),
          name: 'edited',
        );
      } else {
        await repository.updateMilestone(
          (await db.select(db.projectMilestones).get()).first,
          title: 'edited',
        );
      }
      final original = await db.select(db.outboxMutations).getSingle();
      final table = entity == 'project' ? 'projects' : 'project_milestones';
      await db.customStatement(
        "CREATE TRIGGER fail_ack BEFORE UPDATE ON $table BEGIN SELECT RAISE(ABORT, 'ACK write failed'); END",
      );
      expect(await engine().syncOnce(), SyncState.error);
      final failed = await db.select(db.outboxMutations).getSingle();
      expect(failed.status, OutboxStatus.inFlight);
      expect(failed.mutationId, original.mutationId);
      await db.close();
      db = open();
      await db.customStatement('DROP TRIGGER fail_ack');
      expect(await engine().syncOnce(), SyncState.idle);
      expect(api.ids, [original.mutationId, original.mutationId]);
      final acknowledged = await db.select(db.outboxMutations).getSingle();
      expect(acknowledged.status, OutboxStatus.acknowledged);
      expect(acknowledged.payloadJson, original.payloadJson);
      expect(acknowledged.baseVersion, original.baseVersion);
      await db.close();
    });
    test(
      '$entity concurrent edit survives ACK and rebases next mutation',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final api = GatedApi();
        final engine = SyncEngine(
          database: db,
          config: fixture.TestConfig(),
          apiClient: api,
          includeChat: false,
        );
        await engine.applySnapshot(fixture.snapshot());
        final repository = ProjectRepository(db);
        Future<void> edit(String name) async {
          if (entity == 'project') {
            await repository.updateProject(
              await db.select(db.projects).getSingle(),
              name: name,
            );
          } else {
            final m = (await db.select(db.projectMilestones).get()).first;
            await repository.updateMilestone(m, title: name);
          }
        }

        await edit('first');
        final original = await db.select(db.outboxMutations).getSingle();
        final run = engine.syncOnce();
        await api.started.future;
        await edit('second');
        api.release.complete();
        expect(await run, SyncState.idle);
        final pending = (await db.select(db.outboxMutations).get()).singleWhere(
          (r) => r.status == OutboxStatus.pending,
        );
        expect(pending.mutationId, isNot(original.mutationId));
        expect(pending.entityRevision, original.entityRevision + 1);
        expect(pending.baseVersion, 7);
        expect(pending.payloadJson, contains('second'));
        if (entity == 'project') {
          final current = await db.select(db.projects).getSingle();
          expect(
            [
              current.name,
              current.syncStatus,
              current.remoteVersion,
              current.version,
            ],
            ['second', 'pendingUpdate', 7, 7],
          );
        } else {
          final current = (await db.select(db.projectMilestones).get()).first;
          expect(
            [
              current.title,
              current.syncStatus,
              current.remoteVersion,
              current.version,
            ],
            ['second', 'pendingUpdate', 7, 7],
          );
        }
        api.gated = false;
        expect(await engine.syncOnce(), SyncState.idle);
        expect(api.ids, [original.mutationId, pending.mutationId]);
        expect(api.bases, [1, 7]);
      },
    );
  }
  test(
    'second 410 terminates after one recovery and preserves snapshot cursor',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final api = ExpiredApi()..snapshotResponse = fixture.snapshot(cursor: 50);
      final engine = SyncEngine(
        database: db,
        config: fixture.TestConfig(),
        apiClient: api,
        includeChat: false,
      );
      await engine.applySnapshot(fixture.snapshot(cursor: 10));
      expect(await engine.syncOnce(), SyncState.error);
      expect(api.snapshotCalls, 1);
      expect(api.afterCursors, [10, 50]);
      final cursor = (await db.select(db.syncMetadata).get()).singleWhere(
        (r) => r.key == 'serverCursor',
      );
      expect(cursor.value, '50');
    },
  );
  test(
    'dispose drains in-flight old account and suppresses queued runs',
    () async {
      final gate = Completer<SyncState>();
      var runs = 0;
      var disposed = false;
      final coordinator = SyncCoordinator(
        sync: () {
          runs++;
          return gate.future;
        },
        realtime: MobileRealtimeClient(config: fixture.TestConfig()),
      );
      final first = coordinator.requestSync();
      final queued = coordinator.requestSync();
      final disposal = coordinator.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      expect(identical(first, queued), isTrue);
      gate.complete(SyncState.idle);
      await disposal;
      expect(disposed, isTrue);
      expect(runs, 1);
      expect(await coordinator.requestSync(), SyncState.error);
    },
  );
}
