import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

import 'project_milestone_sync_test.dart' as fixture;

class _Cloud extends OrialisApiClient {
  _Cloud() : super(baseUrl: 'http://unused.invalid', deviceId: 'cloud-test');
  final events = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> syncSnapshot() async => {
    'cursor': 0,
    'tasks': [],
    'calendarEvents': [],
    'projects': [],
    'milestones': [],
  };

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    final page = events
        .where((event) => (event['cursor'] as int) > after)
        .toList();
    return {
      'events': page,
      'nextCursor': page.isEmpty ? after : page.last['cursor'],
    };
  }
}

class _QuietRealtime extends MobileRealtimeClient {
  _QuietRealtime() : super(config: AppConfig());
  @override
  Future<void> connect() async {}
}

void main() {
  test(
    'two clients receive cloud edits and deletion without push or manual sync',
    () async {
      final cloud = _Cloud();
      final databases = List.generate(
        2,
        (_) => AppDatabase(executor: AppDatabase.inMemoryExecutor()),
      );
      final clients = <SyncCoordinator>[];
      final connections = <MobileRealtimeClient>[];
      addTearDown(() async {
        for (final client in clients) {
          await client.dispose();
        }
        for (final connection in connections) {
          await connection.dispose();
        }
        for (final db in databases) {
          await db.close();
        }
      });
      for (final db in databases) {
        final connection = _QuietRealtime();
        connections.add(connection);
        final client = SyncCoordinator(
          sync: SyncEngine(
            database: db,
            config: AppConfig(),
            apiClient: cloud,
            includeChat: false,
          ).syncOnce,
          realtime: connection,
          refreshInterval: const Duration(milliseconds: 30),
        );
        clients.add(client);
        await client.start();
      }

      Future<void> waitFor(bool Function(Task) matches) async {
        await Future.wait(
          databases.map(
            (db) => db
                .select(db.tasks)
                .watch()
                .firstWhere((rows) => rows.any(matches)),
          ),
        ).timeout(const Duration(seconds: 5));
      }

      final task = <String, dynamic>{
        'id': 'cloud-task',
        'title': 'Created in cloud',
        'version': 1,
        'completed': false,
        'createdAt': fixture.timestamp,
        'updatedAt': fixture.timestamp,
      };
      cloud.events.add(fixture.upsert(1, 'task', task));
      await waitFor((row) => row.title == 'Created in cloud');
      cloud.events.add(
        fixture.upsert(2, 'task', {
          ...task,
          'title': 'Updated in cloud',
          'version': 2,
        }),
      );
      await waitFor(
        (row) => row.title == 'Updated in cloud' && row.remoteVersion == 2,
      );
      cloud.events.add(fixture.tombstone(3, 'task', 'cloud-task', 3));
      await waitFor((row) => row.deletedAt != null);
      for (final db in databases) {
        final cursor = (await db.select(db.syncMetadata).get()).singleWhere(
          (row) => row.key == 'serverCursor',
        );
        expect(cursor.value, '3');
      }
    },
  );
}
