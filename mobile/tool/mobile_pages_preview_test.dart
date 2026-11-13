// Local visual check, not part of CI: renders phone-size Today/Events pages
// with synthetic data. Output goes to $PREVIEW_OUT (default build/preview).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:orialis_mobile/pages/shared/page_parts.dart';
import 'package:orialis_mobile/pages/today/today_page.dart';

const _fonts = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/System/Library/Fonts/STHeiti Light.ttc',
];

Future<void> _loadFont() async {
  for (final path in _fonts) {
    final file = File(path);
    if (!await file.exists()) continue;
    final bytes = ByteData.sublistView(await file.readAsBytes());
    for (final family in ['sans-serif', 'Ahem', 'Roboto', '.SF UI Text']) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
    return;
  }
}

Future<void> _seed(AppDatabase db, WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  final tasks = container.read(taskRepositoryProvider);
  final schedules = container.read(scheduleRepositoryProvider);
  final now = DateTime.now();
  String day(int offset) => dateKey(now.add(Duration(days: offset)));
  await tasks.create(
    title: '提交季度报告',
    due: day(-1),
    important: true,
    urgent: true,
  );
  await tasks.create(
    title: '回复设计评审意见',
    due: day(0),
    dueTime: '09:00',
    important: true,
    urgent: true,
  );
  await tasks.create(
    title: '预约体检',
    due: day(0),
    urgent: true,
    important: false,
  );
  await tasks.create(
    title: '整理读书笔记',
    due: day(3),
    important: true,
    urgent: false,
  );
  await tasks.create(
    title: '续费云服务器',
    due: day(9),
    important: false,
    urgent: true,
  );
  await tasks.create(title: '给植物换盆', important: false, urgent: false);
  await tasks.create(title: '想一想周末去哪');
  final start = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
    now.minute,
  ).add(const Duration(minutes: 25));
  await schedules.create(
    title: '项目周会',
    startAt: start,
    endAt: start.add(const Duration(hours: 1)),
  );
  await schedules.create(
    title: '健身',
    startAt: start.add(const Duration(hours: 3)),
    endAt: start.add(const Duration(hours: 4)),
  );
  container.dispose();
}

void main() {
  final out = Platform.environment['PREVIEW_OUT'] ?? 'build/preview';
  // e.g. PREVIEW_SIZE=844x390 for phone landscape, 1280x800 for tablets.
  final size = (Platform.environment['PREVIEW_SIZE'] ?? '390x844')
      .split('x')
      .map(double.parse)
      .toList();
  final suffix = size[0] == 390 && size[1] == 844
      ? ''
      : '-${size[0].toInt()}x${size[1].toInt()}';
  for (final page in ['today', 'events']) {
    for (final brightness in Brightness.values) {
      testWidgets('preview $page ${brightness.name}', (tester) async {
        tester.view.physicalSize = Size(size[0] * 2, size[1] * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.runAsync(_loadFont);
        final db = AppDatabase(executor: NativeDatabase.memory());
        await tester.runAsync(() => _seed(db, tester));
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'sans-serif'),
              builder: (context, child) =>
                  Material(type: MaterialType.transparency, child: child),
              home: RepaintBoundary(
                key: key,
                child: LuminaTheme(
                  brightness: brightness,
                  highPerformanceMode: true,
                  data: const LuminaThemeData(
                    neumorphic: true,
                    neumorphicGlass: true,
                  ),
                  child: OrialisMobileNavigationOverlay(
                    destinations: const [
                      NavigationDestination(
                        icon: LuminaIcon(LuminaIcons.today),
                        label: '今日',
                      ),
                      NavigationDestination(
                        icon: LuminaIcon(LuminaIcons.tasks),
                        label: '事件',
                      ),
                      NavigationDestination(
                        icon: LuminaIcon(LuminaIcons.chat),
                        label: '聊天',
                      ),
                      NavigationDestination(
                        icon: LuminaIcon(LuminaIcons.calendar),
                        label: '日历',
                      ),
                      NavigationDestination(
                        icon: LuminaIcon(LuminaIcons.person),
                        label: '我的',
                      ),
                    ],
                    selectedIndex: page == 'today' ? 0 : 1,
                    onDestinationSelected: (_) {},
                    child: page == 'today'
                        ? const TodayPage()
                        : const EventsPage(),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await expectLater(
          find.byKey(key),
          matchesGoldenFile('$out/$page-${brightness.name}$suffix.png'),
        );
        // No teardown: closing the in-memory database here deadlocks the
        // tester; run one preview per process (see --plain-name).
      });
    }
  }
}
