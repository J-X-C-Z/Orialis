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

    test('high-performance chrome is cheaper than balanced mode', () {
      final config = LuminaBlurConfig.highPerformanceChrome;
      expect(config.backend, isNot(LuminaBlurBackend.legacyGaussian));
      expect(config.level, LuminaBlurLevel.blurS);
      expect(
        config.level.sigma,
        lessThan(LuminaBlurConfig.flowingGlass.level.sigma),
      );
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
      expect(seen, LuminaBlurLevel.blurS);
      policy.useFlowingGlass();
      expect(seen, LuminaBlurLevel.blurM);
    });

    test(
      'adaptation has recovery hysteresis and respects configured ceiling',
      () {
        final policy = LuminaBlurPolicy.instance;
        policy.useFlowingGlass();
        addTearDown(policy.useFlowingGlass);
        var tick = 0;
        void frames(int count, int costMs) {
          for (var i = 0; i < count; i++) {
            policy.observeFrame(
              build: Duration(milliseconds: costMs),
              raster: const Duration(milliseconds: 4),
              elapsed: Duration(milliseconds: ++tick * 20),
            );
          }
        }

        // Isolated expensive frames and borderline work do not reduce quality.
        for (var i = 0; i < 20; i++) {
          frames(1, 30);
          frames(1, 15);
        }
        expect(policy.chrome.level, LuminaBlurLevel.blurM);
        frames(12, 30);
        expect(policy.chrome.level, LuminaBlurLevel.blurS);
        frames(119, 8);
        expect(policy.chrome.level, LuminaBlurLevel.blurS);
        frames(1, 8);
        expect(policy.chrome.level, LuminaBlurLevel.blurM);
        frames(240, 8);
        expect(policy.chrome.level, LuminaBlurLevel.blurM);
        policy.useHighPerformanceChrome();
        frames(240, 8);
        expect(policy.chrome.level, LuminaBlurLevel.blurS);
        policy.useDisabled();
        frames(240, 30);
        expect(policy.chrome.level, LuminaBlurLevel.blurXS);
      },
    );

    test('slow-frame budget accounts for high refresh displays', () {
      final policy = LuminaBlurPolicy.instance;
      policy.useFlowingGlass();
      addTearDown(policy.useFlowingGlass);
      for (var i = 0; i < 12; i++) {
        policy.observeFrame(
          build: const Duration(milliseconds: 11),
          raster: const Duration(milliseconds: 4),
          budget: const Duration(microseconds: 8333),
          elapsed: Duration(milliseconds: i * 12),
        );
      }
      expect(policy.chrome.level, LuminaBlurLevel.blurS);
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
  testWidgets('sliding well follows live blur policy including disabled', (
    tester,
  ) async {
    final policy = LuminaBlurPolicy.instance;
    policy.useFlowingGlass();
    addTearDown(policy.useFlowingGlass);
    await tester.pumpWidget(
      _harness(
        const SizedBox(
          width: 240,
          height: 48,
          child: LuminaSlidingSelection(
            index: 0,
            count: 2,
            child: SizedBox.expand(),
          ),
        ),
        highPerformance: false,
      ),
    );
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      same(LuminaBlurFilters.forConfig(policy.chrome)),
    );
    policy.useHighPerformanceChrome();
    await tester.pump();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      same(LuminaBlurFilters.forConfig(policy.chrome)),
    );
    policy.useDisabled();
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
