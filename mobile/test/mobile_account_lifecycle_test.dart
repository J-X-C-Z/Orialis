import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/database/legacy_database_reader.dart';
import 'package:orialis_mobile/pages/profile/legacy_recovery.dart';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

class MobileConfig extends AppConfig {
  String? username = 'alice';
  String baseUrl = 'https://isolated.test';
  @override
  Future<String> deviceId() async => 'synthetic-provider-phone';
  @override
  Future<String> serverUrl() async => baseUrl;
  @override
  Future<String?> sessionToken() async =>
      username == null ? null : 'synthetic-session';
  @override
  Future<String?> sessionUsername() async => username;
}

class QuietRealtime extends MobileRealtimeClient {
  QuietRealtime(AppConfig config) : super(config: config);
  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('mobile account lifecycle drains old work before scope changes', (
    tester,
  ) async {
    final config = MobileConfig();
    final gate = Completer<SyncState>();
    var runs = 0;
    final realtime = QuietRealtime(config);
    final coordinator = SyncCoordinator(
      sync: () {
        runs++;
        return gate.future;
      },
      realtime: realtime,
    );
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          syncCoordinatorProvider.overrideWithValue(coordinator),
          realtimeClientProvider.overrideWithValue(realtime),
        ],
        child: Consumer(
          builder: (context, value, child) {
            ref = value;
            return const SizedBox();
          },
        ),
      ),
    );
    final originalScope = await config.desktopDatabaseName();
    ref.read(desktopDatabaseNameProvider.notifier).state = originalScope;
    coordinator.requestSync();
    coordinator.requestSync();
    var drained = false;
    final drain = suspendDesktopSync(ref).then((_) => drained = true);
    await tester.pump();
    expect(drained, isFalse);
    expect(config.username, 'alice');
    expect(ref.read(desktopDatabaseNameProvider), originalScope);
    gate.complete(SyncState.idle);
    await drain;
    expect(runs, 1);
    expect(await coordinator.requestSync(), SyncState.error);
    config.username = 'bob';
    await reloadDesktopAccount(ref);
    expect(
      ref.read(desktopDatabaseNameProvider),
      await config.desktopDatabaseName(),
    );
    expect(ref.read(desktopDatabaseNameProvider), isNot(originalScope));
    await tester.pumpWidget(const SizedBox());
    await coordinator.dispose();
  });
  test('mobile A to B to A preserves task message attachment metadata outbox and cursor', () async {
    final directory = await Directory.systemTemp.createTemp('ori106-accounts-');
    addTearDown(() => directory.delete(recursive: true));
    final config = MobileConfig();
    final alice = await config.desktopDatabaseName();
    AppDatabase open(String name) => AppDatabase(
      executor: NativeDatabase(File('${directory.path}/$name.sqlite')),
    );
    var db = open(alice);
    await EventRepository(
      database: db,
      config: config,
    ).createTask(title: 'A task');
    final mutation = await db.select(db.outboxMutations).getSingle();
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            conversationId: 'A-chat',
            id: 'A-message',
            role: 'user',
            content: 'A message',
            createdAt: '2026-10-09',
            attachmentsJson: const Value(
              '[{"id":"A-attachment","localPath":"synthetic-A.bin"}]',
            ),
          ),
        );
    await db
        .into(db.syncMetadata)
        .insert(SyncMetadataCompanion.insert(key: 'serverCursor', value: '73'));
    final message = await db.select(db.messages).getSingle();
    await db.close();
    config.username = 'bob';
    final bob = await config.desktopDatabaseName();
    expect(bob, isNot(alice));
    db = open(bob);
    expect(await db.select(db.tasks).get(), isEmpty);
    expect(await db.select(db.messages).get(), isEmpty);
    expect(await db.select(db.outboxMutations).get(), isEmpty);
    expect(await db.select(db.syncMetadata).get(), isEmpty);
    await EventRepository(
      database: db,
      config: config,
    ).createTask(title: 'B task');
    await db.close();
    config.username = 'alice';
    expect(await config.desktopDatabaseName(), alice);
    db = open(alice);
    expect((await db.select(db.tasks).get()).single.title, 'A task');
    expect(await db.select(db.messages).getSingle(), message);
    expect(await db.select(db.outboxMutations).getSingle(), mutation);
    expect((await db.select(db.syncMetadata).get()).single.value, '73');
    await db.close();
  });
  testWidgets(
    'real startup/provider preserves legacy and drains A before B, logout and failed login',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('ori106-provider-'),
      );
      final root = directory!;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async {
            if (call.method == 'getTemporaryDirectory') return root.path;
            throw UnsupportedError('unexpected path lookup: ${call.method}');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );
      final oldHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      var failedLogins = 0;
      final loginPaths = <String>[];
      await tester.runAsync(() async {
        server.listen((request) async {
          await request.drain<void>();
          loginPaths.add(request.uri.path);
          failedLogins++;
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"error":"synthetic unavailable"}');
          await request.response.close();
        });
      });
      addTearDown(() async {
        await server.close(force: true);
        HttpOverrides.global = oldHttpOverrides;
      });
      final config = MobileConfig()
        ..baseUrl = 'http://127.0.0.1:${server.port}';
      late WidgetRef ref;
      final gate = (await tester.runAsync(() async => Completer<SyncState>()))!;
      final oldCoordinator = SyncCoordinator(
        sync: () => gate.future,
        realtime: QuietRealtime(config),
      );
      var coordinatorCreations = 0;
      final overrides = await tester.runAsync(
        () => mobileStartupOverrides(config),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides!,
            databaseDirectoryProvider.overrideWithValue(() async => root),
            realtimeClientProvider.overrideWith((ref) => QuietRealtime(config)),
            syncCoordinatorProvider.overrideWith((providerRef) {
              final coordinator = coordinatorCreations++ == 0
                  ? oldCoordinator
                  : SyncCoordinator(
                      sync: () async => SyncState.idle,
                      realtime: providerRef.read(realtimeClientProvider),
                    );
              providerRef.onDispose(coordinator.dispose);
              return coordinator;
            }),
          ],
          child: Consumer(
            builder: (context, value, child) {
              ref = value;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final legacyFile = File('${root.path}/orialis.sqlite');
        final legacy = AppDatabase(executor: NativeDatabase(legacyFile));
        await EventRepository(
          database: legacy,
          config: config,
        ).createTask(title: 'legacy offline edit');
        final pending = await legacy.select(legacy.outboxMutations).getSingle();
        // An older version must remain readable without a migration on inspection.
        await legacy.customStatement('PRAGMA user_version = 4');
        await legacy.close();
        final legacyHash = sha256.convert(await legacyFile.readAsBytes());
        Future<void> checkLegacy() async {
          expect(
            (await ref.read(legacyDatabaseFileProvider.future))!.path,
            legacyFile.path,
          );
          final reader = LegacyDatabaseReader(legacyFile);
          expect(await reader.availableTables(), contains('outbox_mutations'));
          expect(
            (await reader.readPage('tasks', 0)).single['title'],
            'legacy offline edit',
          );
          expect(
            (await reader.readPage(
              'outbox_mutations',
              0,
            )).single['mutation_id'],
            pending.mutationId,
          );
          await reader.close();
          expect(sha256.convert(await legacyFile.readAsBytes()), legacyHash);
        }

        var db = ref.read(databaseProvider);
        final aliceDb = db;
        expect(
          ref.read(desktopDatabaseNameProvider),
          await config.desktopDatabaseName(),
        );
        expect(
          await db.select(db.tasks).get(),
          isEmpty,
        ); // startup does not consume legacy
        await EventRepository(
          database: db,
          config: config,
        ).createTask(title: 'A task');
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                conversationId: 'A-chat',
                id: 'A-message',
                role: 'user',
                content: 'A message',
                createdAt: '2026-10-09',
                attachmentsJson: const Value('[{"localPath":"A.bin"}]'),
              ),
            );
        await db
            .into(db.syncMetadata)
            .insert(
              SyncMetadataCompanion.insert(key: 'serverCursor', value: '73'),
            );
        final mutation = await db.select(db.outboxMutations).getSingle();
        final message = await db.select(db.messages).getSingle();
        await checkLegacy();
        oldCoordinator.requestSync();
        oldCoordinator.requestSync();
        var switched = false;
        final transition = () async {
          await suspendDesktopSync(ref);
          config.username = 'bob';
          await reloadDesktopAccount(ref);
          switched = true;
        }();
        await Future<void>.delayed(Duration.zero);
        expect(switched, false);
        expect(config.username, 'alice');
        expect(identical(ref.read(databaseProvider), aliceDb), true);
        gate.complete(SyncState.idle);
        await transition;
        db = ref.read(databaseProvider);
        expect(identical(db, aliceDb), false);
        expect(await db.select(db.tasks).get(), isEmpty);
        expect(await db.select(db.messages).get(), isEmpty);
        expect(await db.select(db.outboxMutations).get(), isEmpty);
        expect(await db.select(db.syncMetadata).get(), isEmpty);
        await EventRepository(
          database: db,
          config: config,
        ).createTask(title: 'B task');
        await checkLegacy();
        await suspendDesktopSync(ref);
        config.username = null;
        await reloadDesktopAccount(ref);
        db = ref.read(databaseProvider);
        expect(await db.select(db.tasks).get(), isEmpty);
        expect(await db.select(db.outboxMutations).get(), isEmpty);
        await EventRepository(
          database: db,
          config: config,
        ).createTask(title: 'anonymous offline edit');
        final anonymousScope = ref.read(desktopDatabaseNameProvider);
        // Failed login leaves credentials unchanged, but recreates sync providers.
        final anonymousCoordinator = ref.read(syncCoordinatorProvider);
        await suspendDesktopSync(ref);
        var loginFailed = false;
        final api = OrialisApiClient(
          baseUrl: config.baseUrl,
          deviceId: await config.deviceId(),
          config: config,
        );
        try {
          await api.login(username: 'alice', password: 'synthetic-password');
        } on DioException catch (error) {
          expect(error.response?.statusCode, 503);
          loginFailed = true;
        } finally {
          await reloadDesktopAccount(ref);
        }
        expect(loginFailed, true);
        expect(failedLogins, 1);
        expect(loginPaths, ['/api/v1/auth/login']);
        expect(config.username, isNull);
        expect(ref.read(desktopDatabaseNameProvider), anonymousScope);
        db = ref.read(databaseProvider);
        expect(
          (await db.select(db.tasks).get()).single.title,
          'anonymous offline edit',
        );
        expect(await db.select(db.messages).get(), isEmpty);
        expect(await db.select(db.syncMetadata).get(), isEmpty);
        expect(
          (await db.select(db.outboxMutations).get()).single.entityId,
          (await db.select(db.tasks).get()).single.id,
        );
        final afterFailedLogin = ref.read(syncCoordinatorProvider);
        expect(identical(afterFailedLogin, anonymousCoordinator), false);
        expect(await afterFailedLogin.requestSync(), SyncState.idle);
        await checkLegacy();
        config.username = 'alice';
        await reloadDesktopAccount(ref);
        db = ref.read(databaseProvider);
        expect((await db.select(db.tasks).get()).single.title, 'A task');
        expect(await db.select(db.messages).getSingle(), message);
        expect(await db.select(db.outboxMutations).getSingle(), mutation);
        expect((await db.select(db.syncMetadata).get()).single.value, '73');
        await checkLegacy();
        await db.close();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await oldCoordinator.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await root.delete(recursive: true);
      });
    },
  );
}
