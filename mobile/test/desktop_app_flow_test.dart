import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/news/news_data.dart';

class _DesktopNewsRepository extends NewsRepository {
  _DesktopNewsRepository(super.config);

  @override
  Future<NewsLoadResult> get(String path, {bool requireSession = true}) async {
    final data = switch (path) {
      'github/daily' => [
        {'repository': 'owner/repo', 'ranking': 1, 'description': '桌面资讯仓库'},
      ],
      'github/briefs/daily' => {'title': 'GitHub 日报', 'summary': '桌面端简报'},
      'github/weekly' => <Map<String, dynamic>>[],
      'github/briefs/weekly' => <String, dynamic>{},
      'github/repos/owner/repo' => {
        'repository': 'owner/repo',
        'summary': '仓库详情加载成功',
      },
      _ => <Map<String, dynamic>>[],
    };
    final payload = NewsPayload(
      data: data,
      updatedAt: DateTime.utc(2026, 10, 2),
      stale: false,
      source: 'desktop-test',
      error: null,
    );
    return NewsLoadResult(NewsLoadKind.data, payload: payload);
  }
}

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
    'desktop destinations and offline task creation work at wide and narrow sizes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase(executor: NativeDatabase.memory());
      final config = _LocalConfig();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            desktopModeProvider.overrideWithValue(true),
            chatRepositoryProvider.overrideWith(
              (ref) => throw StateError("Desktop must not create chat"),
            ),
            appConfigProvider.overrideWithValue(config),
            newsConfigProvider.overrideWithValue(config),
            newsRepositoryProvider.overrideWithValue(
              _DesktopNewsRepository(config),
            ),
            syncCoordinatorProvider.overrideWith(
              (ref) => _OfflineSync(
                realtime: ref.read(realtimeClientProvider),
                chatRepository: null,
              ),
            ),
          ],
          child: const OrialisApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('desktop-today-columns')),
        findsOneWidget,
      );
      await tester.tap(find.text('任务').last);
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
      expect(find.text('聊天'), findsNothing);
      await tester.tap(find.text('项目').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('AI Hot').last);
      await tester.pumpAndSettle();
      expect(find.text('AI Hot'), findsWidgets);
      expect(find.text('AIHOT'), findsNothing);
      final liveHotPosition = tester.getTopLeft(find.text('实时热点'));
      final featuredPosition = tester.getTopLeft(find.text('精选资讯'));
      expect(featuredPosition.dy, greaterThan(liveHotPosition.dy));
      expect(featuredPosition.dx, closeTo(liveHotPosition.dx, 1));
      await tester.tap(find.text('GitHub').last);
      await tester.pumpAndSettle();
      expect(find.text('GitHub Trending'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('GitHub 总览'),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('GitHub 总览'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('owner/repo'),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('owner/repo'), findsOneWidget);
      await tester.tap(find.text('owner/repo').last);
      await tester.pumpAndSettle();
      expect(find.text('仓库详情加载成功'), findsWidgets);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('仓库详情加载成功').first)).pop();
      await tester.pumpAndSettle();
      expect(find.text('GitHub Trending'), findsOneWidget);
      await tester.tap(find.text('Project').last);
      await tester.pumpAndSettle();
      expect(find.text('Project'), findsWidgets);
      expect(find.text('今日项目总报'), findsOneWidget);
      expect(find.text('Orialis 资讯'), findsNothing);
      tester.view.physicalSize = const Size(560, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      expect(find.text('未登录'), findsOneWidget);
      for (final size in [
        const Size(1440, 900),
        const Size(1180, 800),
        const Size(1024, 768),
        const Size(900, 720),
        const Size(860, 650),
        const Size(560, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        for (final destination in [
          '今日',
          '任务',
          '项目',
          '日历',
          'AI Hot',
          'GitHub',
          'Project',
          '我的',
        ]) {
          await tester.tap(find.text(destination).last);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$destination at $size',
          );
          if (destination == '今日') {
            expect(
              find.byKey(const ValueKey('desktop-today-columns')),
              size.width >= 1064 ? findsOneWidget : findsNothing,
            );
          }
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );
}
