import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://127.0.0.1:1';
  @override
  Future<String> deviceId() async => 'mobile-title-page-test';
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
    'mobile routes and settings inherit glass titles without changing controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        'orialis.appearanceMode': 'light',
      });
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(430, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase(executor: NativeDatabase.memory());
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(database),
              appConfigProvider.overrideWithValue(_Config()),
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
        final router = GoRouter.of(
          tester.element(find.byType(LuminaTopBar).first),
        );
        final titles = find.byKey(const ValueKey('lumina-glass-card-title'));
        for (final route in ['/events', '/calendar', '/profile', '/system']) {
          router.go(route);
          await tester.pumpAndSettle();
          expect(
            titles,
            findsWidgets,
            reason: '$route has glass section headers',
          );
          expect(
            LuminaGlassTitleScope.of(tester.element(titles.first)),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        }
        router.go('/events');
        await tester.pumpAndSettle();
        await tester.tap(find.text('重要且紧急'));
        await tester.pumpAndSettle();
        expect(find.text('暂无事项'), findsOneWidget);
        await tester.tap(find.text('重要且紧急'));
        await tester.pumpAndSettle();
        expect(find.text('暂无事项'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await database.close();
        await tester.pump(const Duration(seconds: 1));
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
