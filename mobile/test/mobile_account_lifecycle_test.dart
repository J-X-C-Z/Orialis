import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
  @override
  Future<String> serverUrl() async => 'https://isolated.test';
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
}
