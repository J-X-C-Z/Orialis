import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:drift/native.dart';

void main() {
  test('sync states expose clear user-facing copy', () {
    expect(SyncState.idle.label, '已同步');
    expect(SyncState.offline.message, contains('本地修改'));
    expect(SyncState.conflict.label, '需要处理');
    expect(SyncState.conflict.message, contains('已保留'));
    expect(SyncState.authRequired.message, contains('重新登录'));
    expect(SyncState.error.message, contains('重试'));
  });

  test('remote state never overwrites a queued local mutation', () {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final engine = SyncEngine(database: database, config: AppConfig());

    expect(engine.shouldApplyRemote('pendingUpdate', 1, 2), isFalse);
    expect(engine.shouldApplyRemote('pendingDelete', 2, 3), isFalse);
    expect(engine.shouldApplyRemote('synced', 2, 2), isFalse);
    expect(engine.shouldApplyRemote('synced', 2, 3), isTrue);
  });

  test(
    'mutation keys stay stable for retries and change for a new version',
    () {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final engine = SyncEngine(database: database, config: AppConfig());

      expect(
        engine.mutationIdFor('task', 'task-1', 2, 'pendingUpdate'),
        engine.mutationIdFor('task', 'task-1', 2, 'pendingUpdate'),
      );
      expect(
        engine.mutationIdFor('task', 'task-1', 2, 'pendingUpdate'),
        isNot(engine.mutationIdFor('task', 'task-1', 3, 'pendingUpdate')),
      );
    },
  );

  test('only a missing conversation is isolated from message sync', () {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final engine = SyncEngine(database: database, config: AppConfig());

    expect(engine.isIgnorableMessageFetchStatus(404), isTrue);
    expect(engine.isIgnorableMessageFetchStatus(401), isFalse);
    expect(engine.isIgnorableMessageFetchStatus(500), isFalse);
    expect(engine.isIgnorableMessageFetchStatus(null), isFalse);
    expect(engine.isIgnorableMessageCreateStatus(404), isTrue);
    expect(engine.isIgnorableMessageCreateStatus(401), isFalse);
    expect(engine.isIgnorableMessageCreateStatus(500), isFalse);
    expect(
      engine.remoteContainsMessage([
        {'id': 'other'},
        {'id': 'message-1'},
      ], 'message-1'),
      isTrue,
    );
    expect(
      engine.remoteContainsMessage([
        {'id': 'other'},
      ], 'message-1'),
      isFalse,
    );
  });
}
