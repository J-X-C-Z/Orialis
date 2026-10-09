// Runs against the isolated local Node/Control server and a real macOS app
// process. The same disposable credentials and marker are used by Android.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/devices/application/device_center_controller.dart';
import 'package:orialis_mobile/features/devices/data/device_data_source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const username = String.fromEnvironment('JOINT_USERNAME');
  const password = String.fromEnvironment('JOINT_PASSWORD');
  const marker = String.fromEnvironment(
    'JOINT_MARKER',
    defaultValue: '联合验收1002',
  );
  const serverUrl = String.fromEnvironment(
    'ORIALIS_SERVER_URL',
    defaultValue: 'http://127.0.0.1:18444',
  );

  testWidgets(
    'real macOS client syncs both ways with Android and owns an online Node',
    (tester) async {
      expect(AppConfig.isJointAcceptanceBuild, isTrue);
      expect(username, isNotEmpty);
      expect(password, isNotEmpty);
      final server = Uri.parse(serverUrl);
      expect(server.host, '127.0.0.1');
      expect(server.port, 18444);

      final config = AppConfig(desktop: true);
      await config.setServerUrl(serverUrl);
      await LuminaCardMemory.initialize();
      final anonymousDatabase = await config.desktopDatabaseName();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopModeProvider.overrideWithValue(true),
            appConfigProvider.overrideWithValue(config),
            desktopDatabaseNameProvider.overrideWith(
              (ref) => anonymousDatabase,
            ),
          ],
          child: const OrialisApp(),
        ),
      );
      await _settle(tester);

      // Authenticate through the product UI; credentials are compile-time
      // defines and are never included in test output.
      await tester.tap(find.text('我的').last);
      await _settle(tester);
      await _waitForProfileReady(tester, username);
      final logout = find.text('退出登录');
      if (logout.evaluate().isNotEmpty) {
        await tester.tap(logout.first);
        await _settle(tester);
        await _waitForText(tester, '未登录');
      }
      await tester.tap(find.text('未登录').first);
      await _settle(tester);
      final fields = find.byType(EditableText);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), username);
      await tester.enterText(fields.at(1), password);
      await tester.tap(find.text('登录').first);
      await _settle(tester);
      await _waitForLoggedIn(tester, config, username);

      final appContext = tester.element(find.byType(OrialisApp));
      final container = ProviderScope.containerOf(appContext);
      expect(container.read(nodeHeartbeatLifecycleProvider), isNotNull);
      final nodeSource =
          container.read(deviceDataSourceProvider) as NodeApiDeviceDataSource;

      await tester.runAsync(() async {
        // Reuse this isolated package's existing account-scoped Node binding
        // on reruns; otherwise create and confirm one through the real API.
        final binding = await nodeSource.localNodeBinding();
        if (binding == null) {
          final challenge = await nodeSource.startPairing(
            const NodeIdentity(
              displayName: '$marker macOS 真机',
              platform: 'macos',
              nodeVersion: '1.0.1',
            ),
          );
          await nodeSource.confirmPairing(
            challenge.pairingId,
            challenge.confirmationCode,
          );
          await nodeSource.completePairing(challenge);
        } else {
          await nodeSource.heartbeat(binding.$1, binding.$2);
        }
        final local = await nodeSource.localNodeBinding();
        expect(local, isNotNull);
        await nodeSource.heartbeat(local!.$1, local.$2);
      });

      // The Android test may start later. Keep checking the real Node list and
      // local sync until the phone and its first task have reached this client.
      var phoneNodeSeen = false;
      var phoneTaskSeen = false;
      for (var attempt = 0; attempt < 300 && !phoneTaskSeen; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(seconds: 2));
          await container.read(syncEngineProvider).syncOnce();
          final nodes = await nodeSource.listDevices();
          phoneNodeSeen = nodes.any(
            (node) => node.displayName.contains('Android 真机'),
          );
          final tasks = await container
              .read(taskRepositoryProvider)
              .watchTasks()
              .first;
          phoneTaskSeen = tasks.any((task) => task.title == '$marker 手机创建');
          if (nodes.isNotEmpty) {
            final local = await nodeSource.localNodeBinding();
            final localNode = local == null
                ? null
                : nodes.where((node) => node.deviceId == local.$1).firstOrNull;
            if (local != null &&
                localNode != null &&
                localNode.status.name != 'online') {
              await nodeSource.heartbeat(local.$1, local.$2);
            }
          }
        });
        if (phoneNodeSeen && phoneTaskSeen) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        phoneNodeSeen,
        isTrue,
        reason: 'live Node list must include Android',
      );
      expect(phoneTaskSeen, isTrue, reason: 'Android-created task must sync');

      await _openDesktopBranch(tester, '任务');
      final incomingTask = find.text('$marker 手机创建');
      await tester.ensureVisible(incomingTask.first);
      expect(incomingTask, findsWidgets);

      await _openDesktopBranch(tester, '项目');
      var phoneProjectExists = false;
      await tester.runAsync(() async {
        final projects = await container
            .read(projectRepositoryProvider)
            .watchProjects()
            .first;
        phoneProjectExists = projects.any(
          (project) => project.name == '$marker 手机项目',
        );
      });
      if (phoneProjectExists) {
        await _waitForText(tester, '$marker 手机项目');
      }
      await _openDesktopBranch(tester, '日历');
      final scheduleTitle = await _waitForAnyScheduleInUi(
        tester,
        container,
        <String>['$marker 手机日程', '$marker Mac回改日程'],
      );

      await _openDesktopBranch(tester, '任务');
      String? macTaskId;
      await tester.runAsync(() async {
        final tasks = await container
            .read(taskRepositoryProvider)
            .watchTasks()
            .first;
        macTaskId = tasks
            .where((task) => task.title == '$marker Mac创建')
            .firstOrNull
            ?.id;
      });
      if (macTaskId == null) {
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is LuminaIconButton && widget.tooltip == '新增事件',
          ),
        );
        await _settle(tester);
        await tester.enterText(
          find.byType(EditableText).first,
          '$marker Mac创建',
        );
        await tester.ensureVisible(find.widgetWithText(LuminaButton, '保存'));
        await tester.tap(find.widgetWithText(LuminaButton, '保存'));
        await _settle(tester);
        await tester.runAsync(() async {
          await container.read(syncEngineProvider).syncOnce();
          final tasks = await container
              .read(taskRepositoryProvider)
              .watchTasks()
              .first;
          macTaskId = tasks
              .where((task) => task.title == '$marker Mac创建')
              .firstOrNull
              ?.id;
        });
      }
      expect(macTaskId, isNotNull);
      expect(find.text('$marker Mac创建'), findsWidgets);

      await tester.runAsync(() async {
        expect(
          await container.read(syncEngineProvider).syncOnce(),
          SyncState.idle,
        );
      });

      var phoneEditedTaskSeen = false;
      for (var attempt = 0; attempt < 300 && !phoneEditedTaskSeen; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(seconds: 2));
          await container.read(syncEngineProvider).syncOnce();
          final tasks = await container
              .read(taskRepositoryProvider)
              .watchTasks()
              .first;
          phoneEditedTaskSeen = tasks.any(
            (task) => task.id == macTaskId && task.title == '$marker 手机回改Mac',
          );
        });
        if (phoneEditedTaskSeen) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        phoneEditedTaskSeen,
        isTrue,
        reason: 'Android edit must sync back',
      );
      await _openDesktopBranch(tester, '任务');
      await _waitForText(tester, '$marker 手机回改Mac');

      await tester.runAsync(() async {
        final schedules = await container
            .read(scheduleRepositoryProvider)
            .watchAll()
            .first;
        final phoneSchedule = schedules
            .where((item) => item.title == '$marker 手机日程')
            .firstOrNull;
        final macScheduleAlreadyExists = schedules.any(
          (item) => item.title == '$marker Mac回改日程',
        );
        if (phoneSchedule != null) {
          await container
              .read(scheduleRepositoryProvider)
              .update(
                phoneSchedule,
                title: '$marker Mac回改日程',
                startAt: DateTime.parse(phoneSchedule.startAt),
                endAt: DateTime.parse(phoneSchedule.endAt),
                allDay: phoneSchedule.allDay,
                important: phoneSchedule.important,
              );
        } else {
          expect(macScheduleAlreadyExists, isTrue);
        }
        final local = await nodeSource.localNodeBinding();
        expect(local, isNotNull);
        // Reassert the local lease before checking status: the initial
        // cross-device wait can outlast Node's 30-second presence window.
        await nodeSource.heartbeat(local!.$1, local.$2);
        final nodes = await nodeSource.listDevices();
        final localNode = nodes.singleWhere(
          (node) => node.deviceId == local.$1,
        );
        expect(localNode.status.name, 'online');
        expect(
          nodes.any((node) => node.displayName.contains('Android 真机')),
          isTrue,
        );
        final projects = await container
            .read(projectRepositoryProvider)
            .watchProjects()
            .first;
        final phoneProject = projects
            .where((item) => item.name == '$marker 手机项目')
            .firstOrNull;
        if (phoneProject != null) {
          await container
              .read(projectRepositoryProvider)
              .deleteProject(phoneProject);
        }
        expect(
          await container.read(syncEngineProvider).syncOnce(),
          SyncState.idle,
        );
        final remainingProjects = await container
            .read(projectRepositoryProvider)
            .watchProjects()
            .first;
        expect(
          remainingProjects.any((item) => item.name == '$marker 手机项目'),
          isFalse,
        );
        final updatedSchedules = await container
            .read(scheduleRepositoryProvider)
            .watchAll()
            .first;
        expect(
          updatedSchedules.any((item) => item.title == '$marker Mac回改日程'),
          isTrue,
        );
      });

      await _openDesktopBranch(tester, '日历');
      expect(scheduleTitle, anyOf('$marker 手机日程', '$marker Mac回改日程'));
      if (scheduleTitle == '$marker Mac回改日程') {
        await _waitForText(tester, '$marker Mac回改日程');
      } else {
        await _waitForText(tester, '$marker Mac回改日程');
      }
      await _openDesktopBranch(tester, '项目');
      expect(find.text('$marker 手机项目'), findsNothing);

      // Verify the real SSH-reachable Linux Node in the live service and in
      // the product's Device Center, not through a fixture or SDK-only check.
      await tester.runAsync(() async {
        final nodes = await nodeSource.listDevices();
        final linux = nodes.singleWhere(
          (node) =>
              node.platform == 'linux' &&
              node.displayName == 'joint-linux-real',
        );
        expect(linux.status.name, 'online');
      });
      await _openDesktopBranch(tester, '我的');
      await tester.ensureVisible(find.text('设备中心').last);
      await tester.tap(find.text('设备中心').last);
      await _settle(tester);
      await _waitForText(tester, 'joint-linux-real');
      expect(find.text('linux · 在线'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);

      var phoneAcknowledged = false;
      for (var attempt = 0; attempt < 180 && !phoneAcknowledged; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(seconds: 2));
          await container.read(syncEngineProvider).syncOnce();
          final tasks = await container
              .read(taskRepositoryProvider)
              .watchTasks()
              .first;
          phoneAcknowledged = tasks.any(
            (task) => task.title == '$marker 三端验收完成',
          );
        });
        if (phoneAcknowledged) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        phoneAcknowledged,
        isTrue,
        reason:
            'Android must acknowledge the reciprocal edit/delete round trip',
      );
      await _openDesktopBranch(tester, '任务');
      await _waitForText(tester, '$marker 三端验收完成');
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

Future<String> _waitForAnyScheduleInUi(
  WidgetTester tester,
  ProviderContainer container,
  List<String> titles,
) async {
  String? found;
  DateTime? scheduleDate;
  for (var attempt = 0; attempt < 60 && found == null; attempt++) {
    await tester.runAsync(() async {
      await container.read(syncEngineProvider).syncOnce();
      final schedules = await container
          .read(scheduleRepositoryProvider)
          .watchAll()
          .first;
      for (final title in titles) {
        final schedule = schedules
            .where((item) => item.title == title)
            .firstOrNull;
        if (schedule != null) {
          found = title;
          scheduleDate = DateTime.parse(schedule.startAt).toLocal();
          break;
        }
      }
    });
    if (found != null) break;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(found, isNotNull, reason: 'a resumed joint schedule must be present');
  await _selectCalendarDate(tester, scheduleDate!);
  await _waitForText(tester, found!);
  return found!;
}

Future<void> _selectCalendarDate(
  WidgetTester tester,
  DateTime targetDate,
) async {
  final daySelector = find.text('日').last;
  await tester.ensureVisible(daySelector);
  await tester.tap(daySelector);
  await _settle(tester);

  var selected = DateTime.now();
  selected = DateTime(selected.year, selected.month, selected.day);
  final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
  var remaining = target.difference(selected).inDays;
  var steps = 0;
  while (remaining != 0 && steps < 90) {
    final direction = remaining < 0 ? -1 : 1;
    await tester.tap(find.byTooltip(direction < 0 ? '上一天' : '下一天'));
    await _settle(tester);
    selected = DateTime(
      selected.year,
      selected.month,
      selected.day + direction,
    );
    remaining = target.difference(selected).inDays;
    steps++;
  }
  expect(
    remaining,
    0,
    reason: 'calendar must navigate to the real schedule day',
  );
}

Future<void> _settle(WidgetTester tester) async {
  // The desktop shell keeps backdrop/ambient animations scheduled, so
  // pumpAndSettle never reaches global quiescence. Give route and dialog
  // transitions a bounded 600 ms to finish instead.
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openDesktopBranch(WidgetTester tester, String label) async {
  final destination = find.descendant(
    of: find.byKey(const ValueKey('desktop-sidebar')),
    matching: find.text(label),
  );
  expect(destination, findsOneWidget);
  await tester.tap(destination);
  await _settle(tester);
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  var found = false;
  for (var attempt = 0; attempt < 30 && !found; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    found = find.text(text).evaluate().isNotEmpty;
  }
  expect(found, isTrue, reason: 'expected the real UI to display "$text"');
  await tester.ensureVisible(find.text(text).first);
}

Future<void> _waitForLoggedIn(
  WidgetTester tester,
  AppConfig config,
  String username,
) async {
  String? token;
  for (var attempt = 0; attempt < 100; attempt++) {
    token = await config.sessionToken();
    if (token != null && token.isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(token, isNotNull);
  expect(token, isNotEmpty);
  await _waitForText(tester, username);
}

Future<void> _waitForProfileReady(WidgetTester tester, String username) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (find.text(username).evaluate().isNotEmpty ||
        find.text('未登录').evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('profile did not finish checking the session');
}
