import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Blur budget for Lumina Flowing Glass.
///
/// High-performance mode defaults to [blurM]: a downsample-class cost instead
/// of the legacy full-resolution Gaussian (sigma 18). Quality is recovered with
/// tint + micro-noise + rim in the material painter, not with raw sigma.
enum LuminaBlurLevel {
  /// No realtime blur — tint + noise only.
  blurXS(0, resolutionDivisor: 1, passes: 0),

  /// 1/2 resolution class — one cheap Kawase/Gaussian pass.
  blurS(3.5, resolutionDivisor: 2, passes: 1),

  /// 1/4 resolution class — two passes. Default Flowing Glass.
  blurM(5.5, resolutionDivisor: 4, passes: 2),

  /// 1/4 resolution, heavier — three to four passes.
  blurL(9, resolutionDivisor: 4, passes: 3),

  /// 1/8 resolution for large backdrops.
  blurXL(14, resolutionDivisor: 8, passes: 4);

  const LuminaBlurLevel(
    this.sigma, {
    required this.resolutionDivisor,
    required this.passes,
  });

  /// Equivalent full-res Gaussian sigma after Dual-Kawase-style downsampling.
  final double sigma;
  final int resolutionDivisor;
  final int passes;

  bool get enabled => sigma > 0;

  /// Auto-downgrade stops at BlurS — chrome never silently drops to tint-only.
  LuminaBlurLevel get degradedSafe {
    switch (this) {
      case LuminaBlurLevel.blurXL:
        return LuminaBlurLevel.blurL;
      case LuminaBlurLevel.blurL:
        return LuminaBlurLevel.blurM;
      case LuminaBlurLevel.blurM:
        return LuminaBlurLevel.blurS;
      case LuminaBlurLevel.blurS:
      case LuminaBlurLevel.blurXS:
        return LuminaBlurLevel.blurS;
    }
  }

  LuminaBlurLevel get degraded {
    switch (this) {
      case LuminaBlurLevel.blurXL:
        return LuminaBlurLevel.blurL;
      case LuminaBlurLevel.blurL:
        return LuminaBlurLevel.blurM;
      case LuminaBlurLevel.blurM:
        return LuminaBlurLevel.blurS;
      case LuminaBlurLevel.blurS:
        return LuminaBlurLevel.blurXS;
      case LuminaBlurLevel.blurXS:
        return LuminaBlurLevel.blurXS;
    }
  }
}

/// How the level is realized on screen.
enum LuminaBlurBackend {
  /// Planned: true Dual Kawase via multi-pass GPU render targets.
  dualKawase,

  /// Current GPU path: downsample-class ImageFilter.blur (Skia/GPU gaussian
  /// with small sigma ≈ Dual Kawase quality/cost envelope).
  downsampleGaussian,

  /// Legacy full-resolution Gaussian — temporary fallback only.
  legacyGaussian,

  /// Stack / box approximation.
  stackBlur,

  /// Tint + noise fake glass (no shader blur).
  tintNoise,
}

/// Resolves which blur backend to use. Dual Kawase is first choice when
/// available; production currently uses [LuminaBlurBackend.downsampleGaussian]
/// which matches the plan's fallback ladder step 2 (never step back to a
/// full-res large-radius Gaussian in high-performance mode).
class LuminaBlurConfig {
  const LuminaBlurConfig({
    this.level = LuminaBlurLevel.blurM,
    this.backend = LuminaBlurBackend.downsampleGaussian,
    this.autoDowngrade = true,
    this.legacySigma = 18,
  });

  /// Default Flowing Glass level.
  static const LuminaBlurConfig flowingGlass = LuminaBlurConfig();

  /// High-performance chrome (bottom nav) — strong frost, still under the
  /// legacy full-res σ=18 cost (BlurXL ≈ 1/8-res class σ=14).
  static const LuminaBlurConfig highPerformanceChrome = LuminaBlurConfig(
    level: LuminaBlurLevel.blurXL,
    backend: LuminaBlurBackend.downsampleGaussian,
  );

  /// Explicit quality-off switch used by BlurXS / reduce-transparency.
  static const LuminaBlurConfig disabled = LuminaBlurConfig(
    level: LuminaBlurLevel.blurXS,
    backend: LuminaBlurBackend.tintNoise,
    autoDowngrade: false,
  );

  /// Temporary path for A/B against the old sigma-18 filter.
  static const LuminaBlurConfig legacyFallback = LuminaBlurConfig(
    level: LuminaBlurLevel.blurXL,
    backend: LuminaBlurBackend.legacyGaussian,
    autoDowngrade: false,
    legacySigma: 18,
  );

  final LuminaBlurLevel level;
  final LuminaBlurBackend backend;
  final bool autoDowngrade;
  final double legacySigma;

  LuminaBlurConfig copyWith({
    LuminaBlurLevel? level,
    LuminaBlurBackend? backend,
    bool? autoDowngrade,
    double? legacySigma,
  }) => LuminaBlurConfig(
    level: level ?? this.level,
    backend: backend ?? this.backend,
    autoDowngrade: autoDowngrade ?? this.autoDowngrade,
    legacySigma: legacySigma ?? this.legacySigma,
  );

  bool get enabled => level.enabled && backend != LuminaBlurBackend.tintNoise;

  /// Filter mounted under BackdropFilter.
  ui.ImageFilter? imageFilter() {
    if (!enabled) return null;
    final sigma = switch (backend) {
      LuminaBlurBackend.legacyGaussian => legacySigma,
      LuminaBlurBackend.stackBlur => (level.sigma * .85).toDouble(),
      LuminaBlurBackend.dualKawase => level.sigma,
      LuminaBlurBackend.downsampleGaussian => level.sigma,
      LuminaBlurBackend.tintNoise => 0.0,
    };
    if (sigma <= 0) return null;
    return ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
  }

  /// Visual compensation strength (0–1) as blur drops.
  double get compensation {
    switch (level) {
      case LuminaBlurLevel.blurXS:
        return 1;
      case LuminaBlurLevel.blurS:
        return .75;
      case LuminaBlurLevel.blurM:
        return .45;
      case LuminaBlurLevel.blurL:
        return .25;
      case LuminaBlurLevel.blurXL:
        return .1;
    }
  }
}

/// Process-wide blur budget with frame-time driven automatic downgrade.
///
/// Keeps Dual Kawase (when wired) and downsample-Gaussian on one switch so
/// low-end devices degrade a level instead of dropping to tint-only at once.
class LuminaBlurPolicy {
  LuminaBlurPolicy._();

  static final LuminaBlurPolicy instance = LuminaBlurPolicy._();

  LuminaBlurConfig _chrome = LuminaBlurConfig.highPerformanceChrome;
  int _slowFrames = 0;
  bool _timingsHooked = false;
  DateTime _watchStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<LuminaBlurConfig> chromeListenable = ValueNotifier(
    LuminaBlurConfig.highPerformanceChrome,
  );

  LuminaBlurConfig get chrome => _chrome;

  void configure(LuminaBlurConfig config) {
    _chrome = config;
    chromeListenable.value = config;
  }

  void useLegacyFallback() => configure(LuminaBlurConfig.legacyFallback);

  void useFlowingGlass() => configure(LuminaBlurConfig.flowingGlass);

  void useDisabled() => configure(LuminaBlurConfig.disabled);

  void useHighPerformanceChrome() =>
      configure(LuminaBlurConfig.highPerformanceChrome);

  /// Auto-downgrade after a streak of slow frames (frame budget > 16.6ms).
  void ensureFrameWatcher() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    _watchStartedAt = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_chrome.autoDowngrade) {
      _slowFrames = 0;
      return;
    }
    // Warm-up: debug/JIT and first layout are always slow — do not punish
    // chrome for startup frames or the frosted bar disappears immediately.
    if (DateTime.now().difference(_watchStartedAt) <
        const Duration(seconds: 3)) {
      return;
    }
    for (final timing in timings) {
      final total = timing.totalSpan.inMicroseconds;
      // Missed ~60fps budget by a comfortable margin.
      if (total > 22000) {
        _slowFrames++;
      } else if (_slowFrames > 0) {
        _slowFrames--;
      }
    }
    if (_slowFrames >= 16 &&
        _chrome.level != LuminaBlurLevel.blurS &&
        _chrome.level != LuminaBlurLevel.blurXS) {
      _slowFrames = 0;
      configure(_chrome.copyWith(level: _chrome.level.degradedSafe));
    }
  }
}

/// Shared filters keyed by level+sigma so rebuilds reuse the same ui.ImageFilter.
class LuminaBlurFilters {
  static final Map<String, ui.ImageFilter> _cache = {};

  static ui.ImageFilter? forConfig(LuminaBlurConfig config) {
    final filter = config.imageFilter();
    if (filter == null) return null;
    final key = '${config.backend}|${config.level}|${config.legacySigma}';
    return _cache.putIfAbsent(key, () => filter);
  }

  @visibleForTesting
  static void debugClearCache() => _cache.clear();
}
