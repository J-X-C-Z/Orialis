import 'dart:io';

import 'package:flutter/material.dart' show NavigationDestination, ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/pages/profile/legacy_recovery.dart';
import 'package:orialis_mobile/pages/profile/profile_page.dart';
import 'package:orialis_mobile/pages/shared/adaptive_layout.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Assets extends CachingAssetBundle {
  _Assets(this.logo);
  final ByteData logo;
  @override
  Future<ByteData> load(String key) =>
      key == 'assets/branding/orialis-neumorphic-transparent.png'
      ? Future.value(logo)
      : rootBundle.load(key);
}

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'https://profile.invalid';
  @override
  Future<String> deviceId() async => 'profile-layout-test';
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
}

Future<void> _show(WidgetTester tester, Size size, double scale) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const logoPath = 'assets/branding/orialis-neumorphic-transparent.png';
  final localLogo = File(logoPath);
  final logo = (await tester.runAsync(
    () => (localLogo.existsSync() ? localLogo : File('../../mobile/$logoPath'))
        .readAsBytes(),
  ))!;
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const ProfilePage())],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: _Assets(ByteData.sublistView(logo)),
      child: ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(_Config()),
          desktopModeProvider.overrideWithValue(false),
          legacyDatabaseFileProvider.overrideWith((ref) async => null),
        ],
        child: WidgetsApp.router(
          routerConfig: router,
          color: const Color(0xffeeeeee),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: LuminaTheme(
              data: const LuminaThemeData(
                neumorphic: true,
                neumorphicGlass: true,
              ),
              child: OrialisMobileNavigationOverlay(
                destinations: [
                  for (final label in ['今日', '事件', '聊天', '日历', '我的'])
                    NavigationDestination(
                      icon: const LuminaIcon(LuminaIcons.person),
                      label: label,
                    ),
                ],
                selectedIndex: 4,
                onDestinationSelected: (_) {},
                child: child!,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.jxcz.orialis/updates'),
          (call) async => call.method == 'getInstalledVersion' ? '1.4.0' : null,
        );
  });
  for (final size in [
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(390, 844),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'profile groups settings without losing controls at $size / $scale',
        (tester) async {
          await _show(tester, size, scale);
          final scope = OrialisAdaptiveLayout.maybeOf(
            tester.element(find.byType(ProfilePage)),
          )!;
          final columns = find.byKey(
            const ValueKey('profile-adaptive-columns'),
          );
          final actualTwoColumns = columns.evaluate().isNotEmpty;
          expect(
            actualTwoColumns,
            scope.wide &&
                size.width - scope.navigationWidth - 40 >= 560 * scale,
          );
          if (actualTwoColumns) {
            final account = find.byKey(
              const PageStorageKey('profile-account-scroll'),
            );
            final settings = find.byKey(
              const PageStorageKey('profile-settings-scroll'),
            );
            expect(
              tester.getRect(account).right,
              lessThanOrEqualTo(tester.getRect(settings).left),
            );
            expect(
              find.descendant(of: account, matching: find.text('未登录')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: account, matching: find.text('常用功能')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: settings, matching: find.text('外观与体验')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: settings, matching: find.text('数据与同步')),
              findsOneWidget,
            );
          } else {
            expect(
              find.byKey(const PageStorageKey('profile-single-scroll')),
              findsOneWidget,
            );
          }
          for (final title in [
            '未登录',
            '常用功能',
            '屏幕记忆',
            '系统提醒与小组件',
            '外观与体验',
            '高性能模式',
            '设备与连接',
            '设备中心',
            '手环连接',
            '数据与同步',
            '检查并同步',
            '服务器',
          ]) {
            expect(find.text(title), findsOneWidget);
          }
          final performance = find.byType(LuminaSwitch);
          await Scrollable.ensureVisible(
            tester.element(performance),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await tester.tap(performance);
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ProfilePage)),
          );
          expect(container.read(highPerformanceModeProvider), isFalse);
          await Scrollable.ensureVisible(
            tester.element(find.text('深色')),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('深色'));
          await tester.pumpAndSettle();
          expect(container.read(appearanceModeProvider), ThemeMode.dark);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
