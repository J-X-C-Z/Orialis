import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

class _LocalConfig extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://127.0.0.1:1';
  @override
  Future<String> deviceId() async => 'visual-test-device';
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
}

class _OfflineSync extends SyncCoordinator {
  _OfflineSync({required super.realtime, required super.chatRepository})
    : super(sync: () async => SyncState.offline);
  @override
  Future<void> start() async {}
}

void main() {
  testWidgets(
    'five destinations, task creation and calendar views remain usable offline',
    (tester) async {
      tester.view.physicalSize = const Size(432, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase(executor: NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            appConfigProvider.overrideWithValue(_LocalConfig()),
            syncCoordinatorProvider.overrideWith(
              (ref) => _OfflineSync(
                realtime: ref.read(realtimeClientProvider),
                chatRepository: ref.read(chatRepositoryProvider),
              ),
            ),
          ],
          child: const OrialisApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('事件').last);
      await tester.pumpAndSettle();
      expect(find.text('四象限'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is LuminaIconButton && w.tooltip == '新增事件',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, '离线完成界面验收');
      final save = find.widgetWithText(LuminaButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        (await database.select(database.tasks).get()).single.title,
        '离线完成界面验收',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('日历').last);
      await tester.pumpAndSettle();
      for (final view in ['周', '月', '日']) {
        await tester.tap(find.text(view).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('聊天').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      expect(find.text('未登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );
}
