import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/news/news_app.dart';
import 'package:orialis_mobile/news/news_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Config extends AppConfig {
  _Config() : super(news: true);

  @override
  Future<String> serverUrl() async => 'https://news-test.example';
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
}

class _EmptyRepository extends NewsRepository {
  _EmptyRepository(super.config);

  @override
  Future<NewsLoadResult> get(String path, {bool requireSession = true}) async =>
      const NewsLoadResult(NewsLoadKind.empty);
}

class _DelayedConfig extends _Config {
  final loaded = Completer<bool>();

  @override
  Future<bool> highPerformanceMode() => loaded.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('default on can be disabled from account and survives restart', (
    tester,
  ) async {
    final config = _Config();
    Widget app() => ProviderScope(
      overrides: [
        newsConfigProvider.overrideWithValue(config),
        newsRepositoryProvider.overrideWithValue(_EmptyRepository(config)),
      ],
      child: const OrialisNewsApp(),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
      tester.widget<LuminaTheme>(find.byType(LuminaTheme)).highPerformanceMode,
      isTrue,
    );
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is LuminaIconButton && widget.tooltip == '账号与服务地址',
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('news-high-performance-mode'));
    await tester.ensureVisible(toggle);
    expect(tester.widget<LuminaSwitch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<LuminaSwitch>(toggle).value, isFalse);
    expect(LuminaTheme.of(tester.element(toggle)).highPerformanceMode, isFalse);
    expect(await config.highPerformanceMode(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(
      tester.widget<LuminaTheme>(find.byType(LuminaTheme)).highPerformanceMode,
      isFalse,
    );
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is LuminaIconButton && widget.tooltip == '账号与服务地址',
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(await config.highPerformanceMode(), isTrue);
    expect(LuminaTheme.of(tester.element(toggle)).highPerformanceMode, isTrue);
  });

  test('a late preference load cannot replace a newer toggle', () async {
    final config = _DelayedConfig();
    final container = ProviderContainer(
      overrides: [newsConfigProvider.overrideWithValue(config)],
    );
    addTearDown(container.dispose);
    expect(container.read(newsHighPerformanceModeProvider), isTrue);
    await container
        .read(newsHighPerformanceModeProvider.notifier)
        .setEnabled(false);
    config.loaded.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(newsHighPerformanceModeProvider), isFalse);
    expect(
      await SharedPreferences.getInstance().then(
        (prefs) => prefs.getBool('orialis.highPerformanceMode'),
      ),
      isFalse,
    );
  });
}
