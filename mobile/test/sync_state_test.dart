import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/presentation/sync_state_presentation.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:drift/native.dart';

void main() {
  test('sync states expose clear user-facing copy', () {
    expect(
      {
        for (final state in SyncState.values)
          state: [state.label, state.message],
      },
      {
        SyncState.idle: ['已同步', '本地内容已与服务器保持一致。'],
        SyncState.syncing: ['同步中', '正在上传本地修改并获取最新内容。'],
        SyncState.offline: ['等待联网', '当前无法连接服务器，本地修改会继续保留。'],
        SyncState.authRequired: ['需要登录', '登录状态已失效，请重新登录后再同步；本地修改仍然保留。'],
        SyncState.conflict: ['需要处理', '发现版本冲突，本地修改已保留，不会被静默覆盖。'],
        SyncState.error: ['同步失败', '同步没有完成，请稍后重试；本地修改仍然保留。'],
      },
    );
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
