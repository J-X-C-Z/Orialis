import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/desktop_local_changes.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'desktop-local-edit-test';
}

class _QuietRealtime extends MobileRealtimeClient {
  _QuietRealtime() : super(config: _Config());
  @override
  Future<void> connect() async {}
}

class _DomainApi extends OrialisApiClient {
  _DomainApi() : super(baseUrl: 'http://127.0.0.1:1', deviceId: 'test');
  final created = Completer<Map<String, dynamic>>();
  int uploads = 0;
  @override
  Future<Map<String, dynamic>> createTask(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    uploads++;
    created.complete(payload);
    return {...payload, 'version': 1};
  }

  @override
  Future<Map<String, dynamic>> syncSnapshot() async => {
    'cursor': 0,
    'tasks': [],
    'calendarEvents': [],
    'projects': [],
    'milestones': [],
  };
  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async => {
    'nextCursor': after,
    'events': [],
    'hasMore': false,
  };
  @override
  Future<List<Map<String, dynamic>>> listConversations() =>
      throw StateError('Desktop must not request chat');
}

void main() {
  test(
    'foreground desktop task creation uploads without remote hints',
    () async {
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final realtime = _QuietRealtime();
      final api = _DomainApi();
      final engine = SyncEngine(
        database: db,
        config: _Config(),
        apiClient: api,
        includeChat: false,
      );
      final coordinator = SyncCoordinator(
        sync: engine.syncOnce,
        realtime: realtime,
        localChanges: watchDesktopLocalChanges(db),
        localChangeDelay: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        await coordinator.dispose();
        await realtime.dispose();
        await db.close();
      });
      await coordinator.start();
      await EventRepository(
        database: db,
        config: _Config(),
      ).createTask(title: 'Created while desktop stays foreground');
      final sent = await api.created.future.timeout(const Duration(seconds: 3));
      expect(sent['title'], 'Created while desktop stays foreground');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await db.select(db.tasks).get()).single.syncStatus, 'synced');
      expect(api.uploads, 1);
    },
  );
  test(
    'retry bookkeeping and chat do not trigger sync; domain revisions do',
    () async {
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final realtime = _QuietRealtime();
      var runs = 0;
      final coordinator = SyncCoordinator(
        sync: () async {
          runs++;
          return SyncState.offline;
        },
        realtime: realtime,
        localChanges: watchDesktopLocalChanges(db),
        localChangeDelay: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        await coordinator.dispose();
        await realtime.dispose();
        await db.close();
      });
      final store = OutboxStore(db);
      Future<OutboxMutation> enqueue(String type, String id, int revision) =>
          store.enqueue(
            entityType: type,
            entityId: id,
            operation: 'update',
            payloadJson: '{}',
            baseVersion: 1,
            entityRevision: revision,
          );
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 60));
      await coordinator.start();
      await settle();
      final initial = runs;
      await enqueue('conversation', 'excluded', 0);
      await settle();
      expect(runs, initial);
      final mutation = await enqueue('task', 'task-1', 1);
      await settle();
      expect(runs, initial + 1);
      await store.markInFlight(mutation.mutationId);
      await settle();
      await store.markRetryable(mutation.mutationId, 'offline');
      await store.rebasePendingForEntity(
        entityType: 'task',
        entityId: 'task-1',
        baseVersion: 2,
      );
      await settle();
      expect(runs, initial + 1, reason: 'Transport failures must not spin');
      await enqueue('task', 'task-1', 2);
      await settle();
      expect(runs, initial + 2);
      await store.markInFlight(mutation.mutationId);
      await store.acknowledge(mutation.mutationId);
      await settle();
      expect(runs, initial + 2);
      for (final type in ['schedule', 'project', 'project_milestone']) {
        final before = runs;
        await enqueue(type, type, 1);
        await settle();
        expect(runs, before + 1, reason: type);
      }
      await enqueue('task', 'cancel-before-debounce', 0);
      await coordinator.dispose();
      final beforeDispose = runs;
      await settle();
      expect(runs, beforeDispose);
    },
  );
}
