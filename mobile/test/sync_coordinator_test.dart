import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final state in [
    SyncState.idle,
    SyncState.offline,
    SyncState.authRequired,
    SyncState.error,
  ]) {
    test(
      'schedule update only announces a synchronized projection: $state',
      () async {
        final realtime = _TestRealtime();
        var notices = 0;
        final coordinator = SyncCoordinator(
          sync: () async => state,
          realtime: realtime,
          onScheduleUpdate: (_) async {
            notices++;
          },
        );
        await coordinator.start();
        realtime.frames.add(
          const MobileEnvelope(
            type: 'schedule.updated',
            payload: {'eventId': 'schedule-1', 'action': 'cancelled'},
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(notices, state == SyncState.idle ? 1 : 0);
        await coordinator.dispose();
        await realtime.frames.close();
      },
    );
  }
  test('recognizes the canonical sync.change_hint frame type', () {
    expect(SyncCoordinator.isSyncTriggerType('sync.change_hint'), isTrue);
    expect(SyncCoordinator.isSyncTriggerType('change_hint'), isTrue);
    expect(SyncCoordinator.isSyncTriggerType('unrelated'), isFalse);
  });

  test('coalesces sync requests while one run is in flight', () async {
    final gate = Completer<SyncState>();
    var runs = 0;
    final database = AppDatabase(executor: AppDatabase.inMemoryExecutor());
    addTearDown(database.close);
    final coordinator = SyncCoordinator(
      sync: () {
        runs++;
        return gate.future;
      },
      realtime: MobileRealtimeClient(config: AppConfig()),
      chatRepository: ChatRepository(database: database),
    );
    addTearDown(coordinator.dispose);

    final first = coordinator.requestSync();
    final second = coordinator.requestSync();
    expect(identical(first, second), isTrue);
    expect(runs, 1);

    gate.complete(SyncState.idle);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(runs, 2);
  });
}

class _TestRealtime extends MobileRealtimeClient {
  _TestRealtime() : super(config: AppConfig());
  final frames = StreamController<MobileEnvelope>.broadcast();
  @override
  Stream<MobileEnvelope> get events => frames.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
}
