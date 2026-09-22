import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://127.0.0.1:1';
  @override
  Future<String> deviceId() async => 'edge-test';
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
}

class _Offline extends SyncCoordinator {
  _Offline({required super.realtime, required super.chatRepository})
    : super(sync: () async => SyncState.offline);
  @override
  Future<void> start() async {}
}

Widget _app(AppDatabase db) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(db),
    appConfigProvider.overrideWithValue(_Config()),
    syncCoordinatorProvider.overrideWith(
      (ref) => _Offline(
        realtime: ref.read(realtimeClientProvider),
        chatRepository: ref.read(chatRepositoryProvider),
      ),
    ),
  ],
  child: const OrialisApp(),
);
void main() {
  testWidgets(
    'editing an all-day schedule without changes preserves exclusive end',
    (tester) async {
      tester.view.physicalSize = const Size(432, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(executor: NativeDatabase.memory());
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = DateTime(now.year, now.month, now.day + 1);
      await EventRepository(
        database: db,
        config: _Config(),
      ).createCalendarEvent(
        title: '全天保留测试',
        startAt: start,
        endAt: end,
        allDay: true,
      );
      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日历').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全天保留测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(LuminaButton, '编辑日程'));
      await tester.pumpAndSettle();
      final save = find.widgetWithText(LuminaButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final event = (await db.select(db.calendarEvents).get()).single;
      expect(DateTime.parse(event.endAt), end.toUtc());
      expect(DateTime.parse(event.startAt), start.toUtc());
      expect(event.allDay, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await db.close();
    },
  );
  testWidgets('320dp with 2x text supports destinations and calendar views', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = AppDatabase(executor: NativeDatabase.memory());
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final destination in ['事件', '日历', '我的']) {
      await tester.tap(find.text(destination).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: destination);
      if (destination == '日历') {
        for (final view in ['周', '月', '日']) {
          await tester.tap(find.text(view).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: view);
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await db.close();
  });
}
