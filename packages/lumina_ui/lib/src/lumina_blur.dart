import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Gaussian blur budget for clipped persistent chrome.
/// These are actual ImageFilter sigma values, not downsampling guarantees.
enum LuminaBlurLevel {
  blurXS(0),
  blurS(3.5),
  blurM(5.5),
  blurL(9),
  blurXL(14);

  const LuminaBlurLevel(this.sigma);
  final double sigma;

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

/// All blur variants currently use Flutter's Gaussian filter. Historical
/// backend names remain source-compatible; no multipass/downsampling is claimed.
enum LuminaBlurBackend {
  dualKawase,
  downsampleGaussian,
  legacyGaussian,
  stackBlur,
  tintNoise,
}

class LuminaBlurConfig {
  const LuminaBlurConfig({
    this.level = LuminaBlurLevel.blurM,
    this.backend = LuminaBlurBackend.downsampleGaussian,
    this.autoDowngrade = true,
    this.legacySigma = 18,
  });

  /// Default Flowing Glass level.
  static const LuminaBlurConfig flowingGlass = LuminaBlurConfig();

  /// High-performance chrome keeps a small live frost with the lowest sigma.
  static const LuminaBlurConfig highPerformanceChrome = LuminaBlurConfig(
    level: LuminaBlurLevel.blurS,
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
/// Low-end devices reduce sigma after sustained slow raster/build frames.
class LuminaBlurPolicy {
  LuminaBlurPolicy._();

  static final LuminaBlurPolicy instance = LuminaBlurPolicy._();

  LuminaBlurConfig _chrome = LuminaBlurConfig.highPerformanceChrome;
  LuminaBlurConfig _requested = LuminaBlurConfig.highPerformanceChrome;
  int _slowFrames = 0;
  int _stableFrames = 0;
  Duration? _lastChange;
  bool _timingsHooked = false;
  DateTime _watchStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<LuminaBlurConfig> chromeListenable = ValueNotifier(
    LuminaBlurConfig.highPerformanceChrome,
  );

  LuminaBlurConfig get chrome => _chrome;

  void configure(LuminaBlurConfig config) {
    _slowFrames = 0;
    _stableFrames = 0;
    _lastChange = null;
    _requested = config;
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
    final views = ui.PlatformDispatcher.instance.views;
    final refreshRate = views.isEmpty ? 60.0 : views.first.display.refreshRate;
    final budget = Duration(
      microseconds: (1000000 / (refreshRate > 0 ? refreshRate : 60)).round(),
    );
    for (final timing in timings) {
      observeFrame(
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        budget: budget,
        elapsed: Duration(
          microseconds: timing.timestampInMicroseconds(
            ui.FramePhase.rasterFinish,
          ),
        ),
      );
    }
  }

  /// Deterministic adaptation shared by the frame watcher and policy tests.
  /// A slow streak lowers one level; recovery requires sustained headroom and
  /// a cooldown, so borderline frames cannot repeatedly toggle glass quality.
  @visibleForTesting
  void observeFrame({
    required Duration build,
    required Duration raster,
    required Duration elapsed,
    Duration budget = const Duration(microseconds: 16667),
  }) {
    if (!_requested.autoDowngrade || !_requested.enabled) return;
    final cost = build > raster ? build : raster;
    final ratio = cost.inMicroseconds / budget.inMicroseconds;
    if (ratio > 1.25) {
      _slowFrames++;
      _stableFrames = 0;
    } else {
      _slowFrames = 0;
      _stableFrames = ratio < .8 ? _stableFrames + 1 : 0;
    }
    final cooled =
        _lastChange == null ||
        elapsed - _lastChange! >= const Duration(seconds: 2);
    var level = _chrome.level;
    if (_slowFrames >= 12 &&
        cooled &&
        level.index > LuminaBlurLevel.blurS.index) {
      level = level.degradedSafe;
    } else if (_stableFrames >= 120 &&
        cooled &&
        level.index < _requested.level.index) {
      level = LuminaBlurLevel.values[level.index + 1];
    }
    if (level == _chrome.level) return;
    _slowFrames = 0;
    _stableFrames = 0;
    _lastChange = elapsed;
    // Keep the requested ceiling, rather than configure() resetting it.
    _chrome = _requested.copyWith(level: level);
    chromeListenable.value = _chrome;
  }
}

/// Shared filters keyed by level+sigma so rebuilds reuse the same ui.ImageFilter.
class LuminaBlurFilters {
  static final Map<String, ui.ImageFilter> _cache = {};

  static ui.ImageFilter? forConfig(LuminaBlurConfig config) {
    if (!config.enabled) return null;
    final key = '${config.backend}|${config.level}|${config.legacySigma}';
    return _cache.putIfAbsent(key, () => config.imageFilter()!);
  }

  @visibleForTesting
  static void debugClearCache() => _cache.clear();
}
