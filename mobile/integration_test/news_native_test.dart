// Real Android acceptance against an owned local API; never a production account.
// Build under the disposable jointAcceptance application ID with private defines.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/news/news_app.dart';
import 'package:orialis_mobile/news/news_data.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const server = String.fromEnvironment('NEWS_TEST_SERVER');
  const username = String.fromEnvironment('NEWS_TEST_USERNAME');
  const password = String.fromEnvironment('NEWS_TEST_PASSWORD');
  const hotTitle = String.fromEnvironment('NEWS_TEST_HOT_TITLE');
  const dailyRepo = String.fromEnvironment('NEWS_TEST_DAILY_REPO');
  const weeklyRepo = String.fromEnvironment('NEWS_TEST_WEEKLY_REPO');
  const controlToken = String.fromEnvironment('NEWS_TEST_CONTROL_TOKEN');

  testWidgets('real phone news login details cache and account revocation', (
    tester,
  ) async {
    expect(AppConfig.isJointAcceptanceBuild, isTrue);
    expect(Uri.parse(server).host, '127.0.0.1');
    expect(username, isNotEmpty);
    expect(password, isNotEmpty);
    final checks = <String, bool>{};
    final config = AppConfig(news: true);
    await tester.runAsync(() async {
      await config.clearSessionToken();
      await config.clearSessionUsername();
      await config.setServerUrl(server);
      await config.setAppearanceMode('light');
      await LuminaCardMemory.initialize();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsConfigProvider.overrideWithValue(config)],
        child: const OrialisNewsApp(),
      ),
    );

    Future<void> waitFor(Finder finder, {int seconds = 25}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (finder.evaluate().isNotEmpty) return;
      }
      expect(finder, findsWidgets);
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot(name);
      expect(tester.takeException(), isNull);
    }

    Future<void> control(String action) async {
      await tester.runAsync(() async {
        final client = HttpClient();
        try {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:18572/$action'),
          );
          request.headers.set('Authorization', 'Bearer $controlToken');
          final response = await request.close();
          final data = jsonDecode(
            await response.transform(utf8.decoder).join(),
          );
          expect(response.statusCode, 200);
          expect(data['ok'], true);
        } finally {
          client.close(force: true);
        }
      });
    }

    await waitFor(find.text('需要登录'));
    await binding.convertFlutterSurfaceToImage();
    await shot('01-signed-out');
    await tester.tap(find.byTooltip('账号与服务地址'));
    await waitFor(find.widgetWithText(TextField, '用户名'));
    await tester.enterText(find.widgetWithText(TextField, '用户名'), username);
    await tester.enterText(find.widgetWithText(TextField, '密码'), password);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '登录'));
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await waitFor(find.text('已登录为 $username'));
    checks['real_ui_login_secure_session'] = true;
    await shot('02-account');
    final dark = find.text('深色').evaluate().isNotEmpty
        ? find.text('深色')
        : find.text('Dark');
    await tester.ensureVisible(dark);
    await tester.tap(dark);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      expect(await config.appearanceMode(), 'dark');
    });
    await shot('02-account-dark');
    final light = find.text('浅色').evaluate().isNotEmpty
        ? find.text('浅色')
        : find.text('Light');
    await tester.tap(light);
    await tester.pump(const Duration(milliseconds: 500));
    checks['theme_switch_persists'] = true;
    await tester.tap(find.byTooltip('返回'));
    await waitFor(find.text(hotTitle));
    expect(find.text('10 条'), findsOneWidget);
    checks['real_aihot_top10'] = true;
    await shot('03-aihot');
    await tester.tap(find.text(hotTitle).first);
    await waitFor(find.text('时间线'));
    checks['real_event_detail_timeline'] = true;
    await shot('04-event');
    await tester.tap(find.byTooltip('返回'));
    await waitFor(find.byTooltip('账号与服务地址'));
    for (final period in ['日报', '周报', '月报']) {
      await tester.ensureVisible(find.text(period));
      await tester.tap(find.text(period));
      await waitFor(find.text('查看报告'));
      await tester.ensureVisible(find.text('查看报告').first);
      await tester.tap(find.text('查看报告').first);
      await waitFor(find.text('$period AI 报告'));
      await waitFor(find.text('查看 AIHOT 原文'));
      expect(find.text('sections'), findsNothing);
      checks['real_aihot_$period'] = true;
      await shot('report-$period');
      await tester.tap(find.byTooltip('返回'));
      await waitFor(find.byTooltip('账号与服务地址'));
    }
    await tester.tap(find.text('GitHub').last);
    await waitFor(find.text(dailyRepo));
    checks['grounded_daily_brief_and_ranking'] = true;
    await shot('05-github-daily');
    await tester.tap(find.text('周榜'));
    await waitFor(find.text(weeklyRepo));
    checks['independent_weekly_ranking'] = true;
    await tester.ensureVisible(find.text(weeklyRepo).first);
    await tester.tap(find.text(weeklyRepo).first);
    await waitFor(find.text('详情'));
    await shot('06-repository');
    await tester.ensureVisible(find.text('打开 GitHub 仓库'));
    await tester.tap(find.text('打开 GitHub 仓库'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await control('verify-link-return');
    await waitFor(find.byTooltip('返回'));
    checks['external_link_handed_to_android'] = true;
    await tester.tap(find.byTooltip('返回'));
    await waitFor(find.text(weeklyRepo));
    checks['detail_back_preserves_weekly'] = true;
    await tester.tap(find.text('Projects').last);
    await waitFor(find.text('尚未收到该账号的项目秘书报告'));
    checks['genuine_empty_projects'] = true;
    await shot('07-projects-empty');
    await tester.tap(find.text('AIHOT').last);
    await waitFor(find.text(hotTitle));
    await control('disconnect');
    try {
      await tester.tap(find.byTooltip('刷新'));
      await waitFor(find.text('离线缓存 · '), seconds: 40);
      expect(find.text(hotTitle), findsWidgets);
      await tester.runAsync(() async {
        final result = await NewsRepository(config).get('aihot/hot');
        expect(result.kind, NewsLoadKind.offline);
        expect(result.payload?.items.first['title'], hotTitle);
      });
      checks['real_transport_loss_retains_cached_hot'] = true;
      await shot('08-offline-cache');
    } finally {
      await control('reconnect');
    }
    await tester.tap(find.byTooltip('刷新'));
    await waitFor(find.text(hotTitle));
    await tester.runAsync(() async {
      final result = await NewsRepository(config).get('aihot/hot');
      expect(result.kind, NewsLoadKind.data);
      // A reachable server may still truthfully mark its source cache stale.
      expect(result.payload?.items.first['title'], hotTitle);
    });
    checks['transport_recovery'] = true;
    await tester.tap(find.byTooltip('账号与服务地址'));
    await waitFor(find.text('退出登录'));
    await tester.ensureVisible(find.text('退出登录'));
    await tester.tap(find.text('退出登录'));
    await waitFor(find.widgetWithText(TextField, '用户名'));
    await tester.tap(find.byTooltip('返回'));
    await waitFor(find.text('需要登录'));
    expect(find.text(hotTitle), findsNothing);
    checks['logout_revokes_visible_cached_content'] = true;
    await shot('09-signed-out');
    await tester.runAsync(() async {
      expect(await config.sessionToken(), isNull);
      await config.setServerUrl(AppConfig.defaultServerUrl);
    });
    binding.reportData = {
      'checks': checks,
      'source':
          'real Android and owned isolated HTTP; previously captured public sources and real Nagi briefs',
      'productionChanged': false,
    };
  }, timeout: const Timeout(Duration(minutes: 5)));
}
