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
}
