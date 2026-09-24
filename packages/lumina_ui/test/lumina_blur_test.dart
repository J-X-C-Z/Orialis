import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _harness(Widget child, {bool highPerformance = true}) => LuminaTheme(
  highPerformanceMode: highPerformance,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: Center(child: child),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LuminaBlurLevel', () {
    test('BlurXS disables realtime blur', () {
      expect(LuminaBlurLevel.blurXS.enabled, isFalse);
      expect(LuminaBlurConfig.disabled.imageFilter(), isNull);
    });

    test('default Flowing Glass is BlurM downsample gaussian', () {
      final config = LuminaBlurConfig.flowingGlass;
      expect(config.level, LuminaBlurLevel.blurM);
      expect(config.backend, LuminaBlurBackend.downsampleGaussian);
      expect(config.enabled, isTrue);
      expect(config.level.sigma, lessThan(18));
      expect(config.imageFilter(), isNotNull);
    });

    test('high-performance chrome is BlurXL not legacy full-res gaussian', () {
      final config = LuminaBlurConfig.highPerformanceChrome;
      expect(config.backend, isNot(LuminaBlurBackend.legacyGaussian));
      expect(config.level, LuminaBlurLevel.blurXL);
      expect(config.imageFilter(), isNotNull);
    });

    test('auto-downgrade never drops chrome below BlurS', () {
      expect(LuminaBlurLevel.blurXL.degradedSafe, LuminaBlurLevel.blurL);
      expect(LuminaBlurLevel.blurL.degradedSafe, LuminaBlurLevel.blurM);
      expect(LuminaBlurLevel.blurM.degradedSafe, LuminaBlurLevel.blurS);
      expect(LuminaBlurLevel.blurS.degradedSafe, LuminaBlurLevel.blurS);
    });

    test('legacy fallback keeps sigma 18 for A/B only', () {
      final config = LuminaBlurConfig.legacyFallback;
      expect(config.backend, LuminaBlurBackend.legacyGaussian);
      expect(config.legacySigma, 18);
      expect(config.autoDowngrade, isFalse);
    });

    test('levels degrade toward BlurXS', () {
      expect(LuminaBlurLevel.blurXL.degraded, LuminaBlurLevel.blurL);
      expect(LuminaBlurLevel.blurL.degraded, LuminaBlurLevel.blurM);
      expect(LuminaBlurLevel.blurM.degraded, LuminaBlurLevel.blurS);
      expect(LuminaBlurLevel.blurS.degraded, LuminaBlurLevel.blurXS);
      expect(LuminaBlurLevel.blurXS.degraded, LuminaBlurLevel.blurXS);
    });

    test('compensation rises as blur budget drops', () {
      final xl = LuminaBlurConfig.flowingGlass.copyWith(
        level: LuminaBlurLevel.blurXL,
      );
      final m = LuminaBlurConfig.flowingGlass;
      final xs = LuminaBlurConfig.disabled;
      expect(m.compensation, greaterThan(xl.compensation));
      expect(xs.compensation, greaterThan(m.compensation));
    });

    test('policy configure notifies listeners', () {
      final policy = LuminaBlurPolicy.instance;
      var seen = policy.chromeListenable.value.level;
      policy.chromeListenable.addListener(() {
        seen = policy.chromeListenable.value.level;
      });
      policy.useLegacyFallback();
      expect(seen, LuminaBlurLevel.blurXL);
      policy.useHighPerformanceChrome();
      expect(seen, LuminaBlurLevel.blurXL);
      policy.useFlowingGlass();
      expect(seen, LuminaBlurLevel.blurM);
    });

    test('filters are cached by backend and level', () {
      LuminaBlurFilters.debugClearCache();
      final a = LuminaBlurFilters.forConfig(LuminaBlurConfig.flowingGlass);
      final b = LuminaBlurFilters.forConfig(LuminaBlurConfig.flowingGlass);
      expect(identical(a, b), isTrue);
      final legacy = LuminaBlurFilters.forConfig(
        LuminaBlurConfig.legacyFallback,
      );
      expect(identical(a, legacy), isFalse);
    });
  });

  testWidgets('chrome backdrop uses new blur policy not raw sigma 18', (
    tester,
  ) async {
    LuminaBlurPolicy.instance.useFlowingGlass();
    await tester.pumpWidget(
      _harness(
        LuminaSurface(
          glass: true,
          backdrop: true,
          onTap: () {},
          child: const SizedBox(width: 240, height: 56),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, isNotNull);
  });

  testWidgets('BlurXS backdrop does not mount BackdropFilter', (tester) async {
    LuminaBlurPolicy.instance.useDisabled();
    addTearDown(LuminaBlurPolicy.instance.useFlowingGlass);
    await tester.pumpWidget(
      _harness(
        LuminaSurface(
          glass: true,
          backdrop: true,
          onTap: () {},
          child: const SizedBox(width: 240, height: 56),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
