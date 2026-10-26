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
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/news/news_data.dart';
import 'package:orialis_mobile/pages/chat/chat_page.dart';
import 'package:orialis_mobile/pages/shared/desktop_insights.dart';
import 'package:orialis_mobile/pages/shell/desktop_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DesktopConfig extends AppConfig {
  @override
  Future<String> deviceId() async => 'desktop-hybrid-test';

  @override
  Future<String?> sessionToken() async => null;

  @override
  Future<String?> sessionUsername() async => null;
}

class _OfflineNewsRepository extends NewsRepository {
  _OfflineNewsRepository(super.config);

  @override
  Future<NewsLoadResult> get(String path, {bool requireSession = true}) async =>
      NewsLoadResult(
        NewsLoadKind.data,
        payload: NewsPayload(
          data: const <Map<String, dynamic>>[],
          updatedAt: DateTime.utc(2026, 10, 25),
          stale: false,
          source: 'desktop-hybrid-test',
          error: null,
        ),
      );
}

class _OfflineSync extends SyncCoordinator {
  _OfflineSync({required super.realtime})
    : super(sync: () async => SyncState.offline, chatRepository: null);

  @override
  Future<void> start() async {}
}

void main() {
  testWidgets(
    'desktop entry uses the new theme, shows insights, and opens routed chat',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = AppDatabase(executor: NativeDatabase.memory());
      final repository = ChatRepository(database: database);
      final config = _DesktopConfig();
      final realtime = MobileRealtimeClient(config: config);
      final sync = _OfflineSync(realtime: realtime);
      Future<void> disposeApp() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await sync.dispose();
        await realtime.dispose();
        await database.close();
      }

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(database),
              chatRepositoryProvider.overrideWithValue(repository),
              desktopModeProvider.overrideWithValue(true),
              desktopDatabaseNameProvider.overrideWith(
                (ref) => 'desktop-alice',
              ),
              appConfigProvider.overrideWithValue(config),
              newsConfigProvider.overrideWithValue(config),
              newsRepositoryProvider.overrideWithValue(
                _OfflineNewsRepository(config),
              ),
              realtimeClientProvider.overrideWithValue(realtime),
              syncCoordinatorProvider.overrideWithValue(sync),
            ],
            child: const OrialisApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DesktopInsightsPanel), findsOneWidget);
        final theme = LuminaTheme.of(tester.element(find.byType(DesktopShell)));
        expect(theme.data.neumorphic, isTrue);
        expect(theme.data.neumorphicGlass, isTrue);
        tester.view.physicalSize = const Size(1439, 900);
        await tester.pumpAndSettle();
        expect(find.byType(DesktopInsightsPanel), findsNothing);
        tester.view.physicalSize = const Size(1440, 900);
        await tester.pumpAndSettle();
        expect(find.byType(DesktopInsightsPanel), findsOneWidget);

        final router = GoRouter.of(tester.element(find.byType(DesktopShell)));
        router.go(
          '/chat?conversationId=desktop-existing&messageId=notice-7&shareId=share-3',
        );
        await tester.pumpAndSettle();

        final chat = tester.widget<ChatPage>(find.byType(ChatPage));
        expect(chat.conversationId, 'desktop-existing');
        expect(chat.messageId, 'notice-7');
        expect(chat.shareId, 'share-3');
        expect(chat.repository, same(repository));
        expect(chat.key, const ValueKey(('desktop-alice', 'desktop-existing')));
        expect(find.byType(DesktopInsightsPanel), findsNothing);
        expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await disposeApp();
      }
    },
  );

  test(
    'Windows desktop sync includes Chat and advertises its capabilities',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final database = AppDatabase(executor: NativeDatabase.memory());
      final config = _DesktopConfig();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          desktopModeProvider.overrideWithValue(true),
          appConfigProvider.overrideWithValue(config),
        ],
      );
      addTearDown(() async {
        await container.read(syncCoordinatorProvider).dispose();
        await container.read(realtimeClientProvider).dispose();
        container.dispose();
        await database.close();
        debugDefaultTargetPlatformOverride = previousPlatform;
      });

      final engine = container.read(syncEngineProvider);
      final realtime = container.read(realtimeClientProvider);
      final coordinator = container.read(syncCoordinatorProvider);
      expect(engine.includeChat, isTrue);
      expect(realtime.platform, 'windows');
      expect(
        realtime.advertisedCapabilities,
        MobileRealtimeClient.clientCapabilities,
      );
      expect(
        coordinator.chatRepository,
        same(container.read(chatRepositoryProvider)),
      );
    },
  );
}
