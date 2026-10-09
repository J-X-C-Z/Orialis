// Physical Android acceptance. Real HTTP, secure storage and on-device database.
// Build only as the isolated top.jxcz.orialis.jointacceptance package.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/devices/application/device_center_controller.dart';
import 'package:orialis_mobile/features/devices/data/device_data_source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const username = String.fromEnvironment('JOINT_USERNAME');
  const password = String.fromEnvironment('JOINT_PASSWORD');
  const marker = String.fromEnvironment('JOINT_MARKER', defaultValue: '联合验收');
  testWidgets('physical Android and macOS share real account and durable nodes', (tester) async {
    expect(AppConfig.isJointAcceptanceBuild, isTrue);
    expect(username, isNotEmpty);
    final config = AppConfig();
    final url = await config.serverUrl();
    expect(Uri.parse(url).host, '127.0.0.1');
    await tester.runAsync(() async {
      final api = OrialisApiClient(baseUrl: url, deviceId: await config.deviceId(), config: config);
      await api.login(username: username, password: password);
      await config.setSessionUsername(username);
      await LuminaCardMemory.initialize();
    });
    await tester.pumpWidget(ProviderScope(overrides: [appConfigProvider.overrideWithValue(config)], child: const OrialisApp()));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    final context = tester.element(find.byType(OrialisApp));
    final container = ProviderScope.containerOf(context);
    final source = container.read(deviceDataSourceProvider) as NodeApiDeviceDataSource;
    await tester.runAsync(() async {
      final binding = await source.localNodeBinding();
      String id;
      if (binding == null) {
        final challenge = await source.startPairing(const NodeIdentity(displayName: '联合验收 Android 真机', platform: 'android', nodeVersion: '1.0.1'));
        // Explicit consent applies only to this disposable test account and package.
        await source.confirmPairing(challenge.pairingId, challenge.confirmationCode);
        id = await source.completePairing(challenge);
      } else {
        id = binding.$1;
        await source.heartbeat(binding.$1, binding.$2);
      }
      await container.read(syncEngineProvider).syncOnce();
      final devices = await source.listDevices();
      expect(devices.any((d) => d.deviceId == id), isTrue);
    });
    await tester.tap(find.text('事件').last);
    await tester.pumpAndSettle();
    var existing = false;
    await tester.runAsync(() async {
      existing = (await container.read(taskRepositoryProvider).watchTasks().first).any((t) => t.title == '$marker 手机创建');
    });
    if (!existing) {
    await tester.tap(find.byWidgetPredicate((w) => w is LuminaIconButton && w.tooltip == '新增事件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '$marker 手机创建');
    await tester.ensureVisible(find.widgetWithText(LuminaButton, '保存'));
    await tester.tap(find.widgetWithText(LuminaButton, '保存'));
    await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      expect(await container.read(syncEngineProvider).syncOnce(), SyncState.idle);
      final projects = await container.read(projectRepositoryProvider).watchProjects().first;
      if (!projects.any((p) => p.name == '$marker 手机项目')) await container.read(projectRepositoryProvider).createProject(name: '$marker 手机项目');
      final now = DateTime.now();
      final schedules = await container.read(scheduleRepositoryProvider).watchAll().first;
      if (!schedules.any((s) => s.title == '$marker 手机日程' || s.title == '$marker Mac回改日程')) await container.read(scheduleRepositoryProvider).create(title: '$marker 手机日程', startAt: now.add(const Duration(hours: 1)), endAt: now.add(const Duration(hours: 2)));
      expect(await container.read(syncEngineProvider).syncOnce(), SyncState.idle);
    });
    // Wait for the separate native macOS product to create its reciprocal task.
    var received = false;
    for (var i = 0; i < 300 && !received; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
        await container.read(syncEngineProvider).syncOnce();
        final tasks = await container.read(taskRepositoryProvider).watchTasks().first;
        received = tasks.any((t) => t.title == '$marker Mac创建');
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(received, isTrue, reason: 'native macOS task must arrive on physical phone');
    await tester.tap(find.text('无截止').first);
    await tester.pumpAndSettle();
    final remote = find.text('$marker Mac创建');
    await tester.ensureVisible(remote.first);
    expect(remote, findsWidgets);
    await tester.runAsync(() async {
      final tasks = await container.read(taskRepositoryProvider).watchTasks().first;
      final macTask = tasks.singleWhere((t) => t.title == '$marker Mac创建');
      await container.read(taskRepositoryProvider).update(macTask, title: '$marker 手机回改Mac');
      expect(await container.read(syncEngineProvider).syncOnce(), SyncState.idle);
      final projects = await container.read(projectRepositoryProvider).watchProjects().first;
      expect(projects.any((p) => p.name == '$marker 手机项目'), isTrue);
      final schedules = await container.read(scheduleRepositoryProvider).watchAll().first;
      expect(schedules.any((s) => s.title == '$marker 手机日程'), isTrue);
    });
    var propagated = false;
    for (var i = 0; i < 120 && !propagated; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
        await container.read(syncEngineProvider).syncOnce();
        final projects = await container.read(projectRepositoryProvider).watchProjects().first;
        final schedules = await container.read(scheduleRepositoryProvider).watchAll().first;
        propagated = !projects.any((p) => p.name == '$marker 手机项目') && schedules.any((s) => s.title == '$marker Mac回改日程');
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(propagated, isTrue, reason: 'macOS project deletion and schedule edit must propagate');
    await tester.runAsync(() async {
      await container.read(projectRepositoryProvider).createProject(name: '$marker Android断网标记');
      expect(await container.read(syncEngineProvider).syncOnce(), SyncState.idle);
      var disconnected = false;
      for (var i = 0; i < 20 && !disconnected; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        disconnected = await container.read(syncEngineProvider).syncOnce() == SyncState.offline;
      }
      expect(disconnected, isTrue, reason: 'manager removes actual USB reverse transport');
      await container.read(taskRepositoryProvider).create(title: '$marker 离线任务');
      final offlineTasks = await container.read(taskRepositoryProvider).watchTasks().first;
      expect(offlineTasks.any((t) => t.title == '$marker 离线任务'), isTrue);
      var reconnected = false;
      for (var i = 0; i < 60 && !reconnected; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        reconnected = await container.read(syncEngineProvider).syncOnce() == SyncState.idle;
      }
      expect(reconnected, isTrue, reason: 'real USB transport restored, pending data uploads');
      await container.read(taskRepositoryProvider).create(title: '$marker 三端验收完成');
      expect(await container.read(syncEngineProvider).syncOnce(), SyncState.idle);
    });
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
