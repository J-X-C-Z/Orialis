// Real macOS runtime, persistent native DB and real HTTP optimistic conflict.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/devices/data/device_data_source.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native persistent client retains local edit after real HTTP 409', (tester) async {
    expect(AppConfig.isJointAcceptanceBuild, isTrue);
    final config = AppConfig(desktop: true);
    late OrialisApiClient api;
    await tester.runAsync(() async {
      api = OrialisApiClient(baseUrl: await config.serverUrl(), deviceId: await config.deviceId(), config: config);
      await api.login(username: const String.fromEnvironment('JOINT_USERNAME'), password: const String.fromEnvironment('JOINT_PASSWORD'));
      await config.setSessionUsername(const String.fromEnvironment('JOINT_USERNAME'));
      await LuminaCardMemory.initialize();
    });
    late String name;
    await tester.runAsync(() async { name = await config.desktopDatabaseName(); });
    await tester.runAsync(() async {
      // This is a second native process. Read physical disk before networking
      // can refill the UI database, and re-read the real secure Node binding.
      final disk = AppDatabase(name: name);
      final rows = await disk.select(disk.tasks).get();
      const marker = String.fromEnvironment('JOINT_MARKER');
      expect(rows.any((t) => t.title == '$marker 三端验收完成'), isTrue, reason: 'native database survives process restart');
      await disk.close();
      final source = NodeApiDeviceDataSource(config: config);
      final binding = await source.localNodeBinding();
      expect(binding, isNotNull, reason: 'secure Node credentials survive process restart');
      await source.heartbeat(binding!.$1, binding.$2);
      source.dispose();
    });
    await tester.pumpWidget(ProviderScope(overrides: [
      desktopModeProvider.overrideWithValue(true), appConfigProvider.overrideWithValue(config),
      desktopDatabaseNameProvider.overrideWith((ref) => name),
    ], child: const OrialisApp()));
    await tester.pump(const Duration(seconds: 1));
    final container = ProviderScope.containerOf(tester.element(find.byType(OrialisApp)));
    await tester.runAsync(() async {
      await container.read(syncCoordinatorProvider).dispose();
      final tasks = container.read(taskRepositoryProvider);
      final engine = container.read(syncEngineProvider);
      final marker = 'native-conflict-${const Uuid().v4()}';
      await tasks.create(title: marker);
      expect(await engine.syncOnce(), SyncState.idle);
      final local = (await tasks.watchTasks().first).singleWhere((t) => t.title == marker);
      expect(local.remoteVersion, greaterThan(0));
      await api.updateTask(local.id, {'title': '$marker remote winner', 'baseVersion': local.remoteVersion}, const Uuid().v4());
      await tasks.update(local, title: '$marker retained local intent');
      expect(await engine.syncOnce(), SyncState.conflict);
      final retained = (await tasks.watchTasks().first).singleWhere((t) => t.id == local.id);
      expect(retained.title, '$marker retained local intent');
      expect(retained.syncStatus, 'pendingUpdate');
      expect(retained.remoteVersion, local.remoteVersion);
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
