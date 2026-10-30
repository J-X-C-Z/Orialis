import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/features/system_integration/schedule_tracking_button.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_snapshot.dart';
import 'package:orialis_mobile/features/system_integration/system_integration_controller.dart';

import 'system_integration_test.dart' show FakeConfig, event;

class _TrackingController extends SystemIntegrationController {
  _TrackingController(AppDatabase db, FakeConfig config)
    : super(database: db, config: config, supported: true) {
    enabled = true;
  }
  String? tracked;
  int starts = 0;
  @override
  Future<String?> trackedScheduleId() async => tracked;
  @override
  Future<Map<Object?, Object?>?> status() async => {
    'notificationsEnabled': true,
  };
  @override
  Future<bool> startScheduleTracking(String id) async {
    starts++;
    tracked = id;
    return true;
  }

  @override
  Future<bool> stopScheduleTracking(String id) async {
    tracked = null;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live schedules are independent of reminders and exclude invalid lifetimes',
    () {
      final now = DateTime.utc(2026, 10, 31, 12);
      CalendarEvent row(String id, DateTime start, DateTime end) =>
          event(id, start.toIso8601String()).copyWith(
            endAt: end.toIso8601String(),
            reminderMinutes: const Value(null),
          );
      final ongoing = row(
        'ongoing',
        now.subtract(const Duration(hours: 1)),
        now.add(const Duration(hours: 1)),
      );
      final future = row(
        'future',
        now.add(const Duration(hours: 1)),
        now.add(const Duration(hours: 2)),
      );
      final snapshot = buildSystemSnapshot(
        scope: 'alice',
        tasks: [],
        events: [
          ongoing,
          future,
          row('ended', now.subtract(const Duration(hours: 1)), now),
          row('zero', now, now),
          row('backward', now, now.subtract(const Duration(minutes: 1))),
          ongoing.copyWith(id: 'deleted', deletedAt: const Value('deleted')),
          ongoing.copyWith(id: 'malformed', endAt: 'bad'),
        ],
        now: now,
      );
      expect(snapshot['reminders'], isEmpty);
      final live = snapshot['liveSchedules'] as List;
      expect(live.map((row) => row['id']), ['ongoing']);
      expect(
        live.first['endsAtMillis'],
        now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
    },
  );

  testWidgets(
    'manual button starts and stops only the selected ongoing schedule',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final config = FakeConfig();
      final controller = _TrackingController(db, config);
      final now = DateTime.now();
      await db
          .into(db.calendarEvents)
          .insert(
            event(
                  'live',
                  now.subtract(const Duration(minutes: 1)).toIso8601String(),
                )
                .copyWith(
                  endAt: now.add(const Duration(hours: 1)).toIso8601String(),
                )
                .toCompanion(false),
          );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appConfigProvider.overrideWithValue(config),
            systemIntegrationProvider.overrideWithValue(controller),
          ],
          child: WidgetsApp(
            color: const Color(0xff000000),
            builder: (context, _) => LuminaTheme(
              child: DefaultTextStyle(
                style: const LuminaTextTheme(LuminaColors(dark: false))
                    .bodyMedium,
                child: Navigator(
                  onGenerateRoute: (_) => PageRouteBuilder<void>(
                    pageBuilder: (_, a, b) => const Center(
                      child: ScheduleTrackingButton(eventId: 'live'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.starts, 0);
      expect(find.text('跟踪此日程'), findsOneWidget);
      await tester.tap(find.text('跟踪此日程'));
      await tester.pumpAndSettle();
      expect(controller.tracked, 'live');
      expect(controller.starts, 1);
      expect(find.text('停止跟踪此日程'), findsOneWidget);
      await tester.tap(find.text('停止跟踪此日程'));
      await tester.pumpAndSettle();
      expect(controller.tracked, isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await controller.dispose();
      await db.close();
    },
  );

  test(
    'tracking checks consent, live row, account and native denial',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final config = FakeConfig();
      const channel = MethodChannel('test/schedule-tracking');
      final calls = <MethodCall>[];
      var nativeAccepted = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'startScheduleTracking' ||
                call.method == 'stopScheduleTracking') {
              return nativeAccepted;
            }
            if (call.method == 'trackedScheduleId') return 'live';
            return null;
          });
      final controller = SystemIntegrationController(
        database: db,
        config: config,
        channel: channel,
        supported: true,
      );
      await controller.start();
      final now = DateTime.now();
      final live =
          event(
            'live',
            now.subtract(const Duration(minutes: 1)).toIso8601String(),
          ).copyWith(
            endAt: now.add(const Duration(hours: 1)).toIso8601String(),
            reminderMinutes: const Value(null),
          );
      await db.into(db.calendarEvents).insert(live.toCompanion(false));
      expect(await controller.startScheduleTracking('live'), false);
      await controller.setEnabled(true);
      expect(await controller.startScheduleTracking('missing'), false);
      expect(await controller.startScheduleTracking('live'), true);
      final start = calls.lastWhere(
        (call) => call.method == 'startScheduleTracking',
      );
      expect(start.arguments['eventId'], 'live');
      expect(start.arguments['scope'], isNotEmpty);
      expect(await controller.trackedScheduleId(), 'live');
      nativeAccepted = false;
      expect(await controller.startScheduleTracking('live'), false);
      expect(await controller.stopScheduleTracking('live'), false);
      nativeAccepted = true;
      expect(await controller.stopScheduleTracking('live'), true);
      for (final changed in [
        live.copyWith(
          startAt: now.add(const Duration(minutes: 30)).toIso8601String(),
        ),
        live.copyWith(
          endAt: now.subtract(const Duration(seconds: 1)).toIso8601String(),
        ),
        live.copyWith(deletedAt: const Value('deleted')),
      ]) {
        await db.update(db.calendarEvents).replace(changed.toCompanion(false));
        expect(await controller.startScheduleTracking('live'), false);
      }
      config.user = 'bob';
      expect(await controller.trackedScheduleId(), isNull);
      expect(await controller.stopScheduleTracking('live'), false);
      expect(await controller.startScheduleTracking('live'), false);
      await controller.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
}
