// Disposable package only: real AlarmManager, notifications and projection.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_snapshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.jxcz.orialis/system');
  testWidgets('native delivery cancellation and account clear on Xiaomi', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Orialis 系统验收'))),
    );
    await tester.runAsync(() async {
      Future<Map<Object?, Object?>> status() async =>
          (await channel.invokeMapMethod<Object?, Object?>('status'))!;
      await channel.invokeMethod<void>('clear');
      final initial = await status();
      expect(initial['notificationsEnabled'], true);
      expect(initial['exactAlarmsEnabled'], true);
      final now = DateTime.now();
      final fire = now.add(const Duration(seconds: 12));
      final schedule = CalendarEvent(
        id: 'native/a ?',
        title: '系统验收日程',
        startAt: fire.toIso8601String(),
        endAt: fire.add(const Duration(minutes: 2)).toIso8601String(),
        allDay: false,
        important: false,
        reminderMinutes: 0,
        version: 1,
        remoteVersion: 0,
        localRevision: 0,
        createdAt: '',
        updatedAt: '',
        syncStatus: 'synced',
      );
      final task = Task(
        id: 'native-task',
        title: '系统验收任务',
        due: systemDate(fire),
        dueTime:
            '${fire.hour.toString().padLeft(2, '0')}:${fire.minute.toString().padLeft(2, '0')}:${fire.second.toString().padLeft(2, '0')}',
        reminderMinutes: 0,
        completed: false,
        version: 1,
        remoteVersion: 0,
        localRevision: 0,
        createdAt: '',
        updatedAt: '',
        syncStatus: 'synced',
      );
      final snapshot = buildSystemSnapshot(
        scope: 'native-acceptance-only',
        tasks: [task],
        events: [schedule],
        now: now,
      );
      await channel.invokeMethod<void>('updateSnapshot', snapshot);
      expect((await status())['projectedReminderCount'], 2);
      var delivered = 0;
      for (var i = 0; i < 35 && delivered < 2; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        delivered = (await status())['activeReminderNotifications'] as int;
      }
      expect(
        delivered,
        2,
        reason: 'Both actual AlarmManager notifications must arrive',
      );
      // Replacing edited/deleted rows must remove their already delivered notices.
      snapshot['reminders'] = <Object>[];
      await channel.invokeMethod<void>('updateSnapshot', snapshot);
      expect((await status())['activeReminderNotifications'], 0);
      expect((await status())['projectedReminderCount'], 0);
      expect(await channel.invokeMethod<bool>('previewReminder'), true);
      expect((await status())['activeReminderNotifications'], 1);
      await channel.invokeMethod<void>('clear');
      expect((await status())['activeReminderNotifications'], 0);
      expect((await status())['projectedReminderCount'], 0);
      expect(await channel.invokeMethod<bool>('previewReminder'), false);
      // Leave a harmless saved widget projection for optional launcher acceptance.
      snapshot['widget'] = {
        'date': systemDate(DateTime.now()),
        'title': '系统验收今日安排',
        'lines': ['仅独立验收包，无真实账号数据'],
        'route': '/today',
      };
      await channel.invokeMethod<void>('updateSnapshot', snapshot);
      debugPrint('SYSTEM_NATIVE_ACCEPTANCE_PASS $initial');
    });
  });
}
