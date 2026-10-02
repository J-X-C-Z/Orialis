import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

class _Config extends AppConfig {
  _Config() : super(desktop: true);
  String server = 'https://example.test';
  String? username;
  String? token;
  @override
  Future<String> serverUrl() async => server;
  @override
  Future<String?> sessionUsername() async => username;
  @override
  Future<String?> sessionToken() async => token;
}

class _NoRequestApi extends OrialisApiClient {
  _NoRequestApi() : super(baseUrl: 'http://127.0.0.1:1', deviceId: 'test');
  @override
  Future<Map<String, dynamic>> syncSnapshot() async =>
      throw StateError('Anonymous desktop must not call server');
}

void main() {
  test(
    'account and server files retain independent data and sync cursors',
    () async {
      final directory = await Directory.systemTemp.createTemp('orialis-scope-');
      addTearDown(() => directory.delete(recursive: true));
      final config = _Config();
      final anonymous = await config.desktopDatabaseName();
      config.token = 'opaque-session';
      config.username = 'alice';
      final alice = await config.desktopDatabaseName();
      AppDatabase open(String name) => AppDatabase(
        executor: NativeDatabase(File('${directory.path}/$name.sqlite')),
      );
      var db = open(alice);
      await EventRepository(
        database: db,
        config: config,
      ).createTask(title: 'Alice local-only task');
      final aliceOutbox = (await db.select(db.outboxMutations).get()).single;
      await db
          .into(db.syncMetadata)
          .insert(
            SyncMetadataCompanion.insert(key: 'serverCursor', value: '73'),
          );
      await db.close();
      config.username = 'bob';
      final bob = await config.desktopDatabaseName();
      db = open(bob);
      expect(await db.select(db.syncMetadata).get(), isEmpty);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await db.select(db.outboxMutations).get(), isEmpty);
      await EventRepository(
        database: db,
        config: config,
      ).createTask(title: 'Bob separate task');
      await db.close();
      config.server = 'https://other.test';
      final otherServer = await config.desktopDatabaseName();
      expect({anonymous, alice, bob, otherServer}, hasLength(4));
      db = open(otherServer);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await db.select(db.outboxMutations).get(), isEmpty);
      await db.close();
      db = open(alice);
      expect((await db.select(db.syncMetadata).get()).single.value, '73');
      expect(
        (await db.select(db.tasks).get()).single.title,
        'Alice local-only task',
      );
      expect((await db.select(db.outboxMutations).get()).single, aliceOutbox);
      await db.close();
      config.server = 'https://example.test/';
      config.username = 'alice';
      expect(await config.desktopDatabaseName(), alice);
      config.token = null;
      expect(await config.desktopDatabaseName(), anonymous);
    },
  );

  test(
    'anonymous desktop skips uploads and preserves local pending mutations',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      await EventRepository(
        database: db,
        config: _Config(),
      ).createTask(title: 'Anonymous local draft');
      final pending = (await db.select(db.outboxMutations).get()).single;
      final sync = SyncEngine(
        database: db,
        config: _Config(),
        apiClient: _NoRequestApi(),
        includeChat: false,
        requireSession: true,
      );
      expect(await sync.syncOnce(), SyncState.authRequired);
      expect(await db.select(db.syncMetadata).get(), isEmpty);
      expect(
        (await db.select(db.tasks).get()).single.title,
        'Anonymous local draft',
      );
      expect((await db.select(db.outboxMutations).get()).single, pending);
    },
  );
}
