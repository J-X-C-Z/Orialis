import 'package:flutter/widgets.dart';

import 'design_tokens.dart';
import 'lumina_tokens_generated.dart';

/// Phone-only opt-in surface language, inspired by the Neumorphism UI registry.
/// Default keeps all existing Lumina renderers, including desktop and News.
enum LuminaVisualStyle { original, neumorphism }

/// Central overrides; defaults reproduce the original Lumina design.
@immutable
class LuminaThemeData {
  const LuminaThemeData({
    this.fontFamily = 'sans-serif',
    this.fontScale = 1,
    this.spacingScale = 1,
    this.radiusScale = 1,
    this.motionScale = 1,
    this.liquidGlass = false,
    this.visualStyle = LuminaVisualStyle.original,
  }) : assert(fontScale > 0),
       assert(spacingScale >= .8),
       assert(radiusScale > 0),
       assert(motionScale >= 0 && motionScale <= 1);
  final String? fontFamily;
  final double fontScale, spacingScale, radiusScale, motionScale;

  /// Clear, grain-free surfaces with diffuse shadows. Opt-in per application.
  final bool liquidGlass;

  /// Opt-in: soft raised cards, inset fields and cool atmospheric shadows.
  final LuminaVisualStyle visualStyle;
}

/// Complete tonal families: raised body, recess, glass accent and text are
/// derived together by LuminaColors, including the dark-mode counterpart.
enum LuminaCardPalette {
  mist(Color(0xFF91A1B1)),
  ocean(Color(0xFF729BBF)),
  sage(Color(0xFF82A68D)),
  amber(Color(0xFFC79B56)),
  rose(Color(0xFFCB7972)),
  lavender(Color(0xFF9B8DB9));

  const LuminaCardPalette(this.tint);
  final Color tint;
  LuminaColors colors({bool dark = false, double? darkProgress}) =>
      LuminaColors(dark: dark, tint: tint, darkProgress: darkProgress);
}

class LuminaColors {
  const LuminaColors({this.dark = false, this.tint, this.neumorphic = false, double? darkProgress})
    : darkProgress = darkProgress ?? (dark ? 1 : 0);
  final bool dark;
  final Color? tint;
  final bool neumorphic;
  final double darkProgress;
  Color tone(Color light, Color dark) => Color.lerp(light, dark, darkProgress)!;
  double toneValue(double light, double dark) =>
      light + (dark - light) * darkProgress;
  Color _tone(Color base, double amount) =>
      tint == null ? base : Color.lerp(base, tint, amount)!;
  Color get ink => neumorphic
      ? tone(const Color(0xFF243046), const Color(0xFFF1F5FC))
      : tone(LuminaBaseColors.ink, LuminaTokenDark.ink);
  Color get paper => neumorphic
      ? tone(const Color(0xFFEAF0F8), const Color(0xFF161E2B))
      : tone(LuminaBaseColors.paper, LuminaTokenDark.paper);
  Color get canvas => paper;
  Color get surface => _tone(
        neumorphic
            ? tone(const Color(0xFFF0F4FA), const Color(0xFF202B3A))
            : tone(LuminaBaseColors.surface, LuminaTokenDark.surface),
        .10,
      );
  Color get raisedSurface => _tone(
        neumorphic
            ? tone(const Color(0xFFF2F6FC), const Color(0xFF293447))
            : tone(const Color(0xFFEDF2F7), const Color(0xFF283746)),
        .13,
      );
  Color get recessedSurface => _tone(
        neumorphic
            ? tone(const Color(0xFFDFE7F3), const Color(0xFF172131))
            : tone(const Color(0xFFE1E8F1), const Color(0xFF141E2A)),
        .23,
      );
  Color get accent => tint == null
      ? (neumorphic
            ? tone(const Color(0xFF477BE0), const Color(0xFF9CC2FF))
            : tone(LuminaBaseColors.accent, LuminaTokenDark.accent))
      : tone(
          Color.lerp(tint, LuminaBaseColors.ink, .25)!,
          Color.lerp(tint, const Color(0xFFFFFFFF), .40)!,
        );
  Color get accentSoft => _tone(
        neumorphic
            ? tone(const Color(0xFFD9E6FB), const Color(0xFF304668))
            : tone(LuminaBaseColors.accentSoft, LuminaTokenDark.accentSoft),
        .30,
      );
  Color get muted => neumorphic
      ? tone(const Color(0xFF74839A), const Color(0xFFA8B5C9))
      : tone(LuminaBaseColors.muted, LuminaTokenDark.muted);
  Color get danger => neumorphic
      ? tone(const Color(0xFFC85462), const Color(0xFFF89AA1))
      : tone(LuminaBaseColors.danger, LuminaTokenDark.danger);
  Color get outline => neumorphic
      ? tone(const Color(0xFFD1DAE9), const Color(0xFF435064))
      : tone(LuminaBaseColors.outline, LuminaTokenDark.outline);
}

class LuminaTextTheme {
  const LuminaTextTheme([
    this.colors = const LuminaColors(),
    this.data = const LuminaThemeData(),
  ]);
  final LuminaColors colors;
  final LuminaThemeData data;
  double _size(double base) => base * data.fontScale;
  // A restrained rim suggests lettering cut into the glass. The principal
  // glyph remains fully opaque, including in dark and high-contrast themes.
  List<Shadow> get _etched => data.liquidGlass || data.visualStyle == LuminaVisualStyle.neumorphism
      ? const []
      : [
          Shadow(
            color: colors.tone(
              const Color(0x66FFFFFF),
              const Color(0x33000000),
            ),
            offset: const Offset(0, 1),
            blurRadius: .35,
          ),
        ];
  // Android's sans-serif resolves through the OEM font map (MiSans on Xiaomi).
  // Other platforms keep their own system UI font and Chinese fallback.
  TextStyle get bodySmall => TextStyle(
    fontFamily: data.fontFamily,
    fontSize: _size(13),
    height: 1.5,
    color: colors.muted,
  );
  TextStyle get bodyMedium => TextStyle(
    fontFamily: data.fontFamily,
    fontSize: _size(15),
    height: 1.5,
    color: colors.ink,
    shadows: _etched,
  );
  TextStyle get bodyLarge => TextStyle(
    fontFamily: data.fontFamily,
    fontSize: _size(17),
    height: 1.5,
    color: colors.ink,
  );
  TextStyle get titleSmall => bodyMedium.copyWith(
    fontSize: _size(18),
    height: 1.3,
    fontWeight: FontWeight.w600,
  );
  TextStyle get titleMedium => bodyLarge.copyWith(
    fontSize: _size(20),
    height: 1.3,
    fontWeight: FontWeight.w600,
  );
  TextStyle get cardTitle => titleMedium.copyWith(fontSize: _size(18));
  TextStyle get recessedTitle => bodyMedium.copyWith(
    fontSize: _size(16),
    height: 1.35,
    fontWeight: FontWeight.w500,
  );
  TextStyle get titleLarge => TextStyle(
    fontFamily: data.fontFamily,
    fontSize: _size(24),
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: colors.ink,
    shadows: _etched,
  );
  TextStyle get headlineSmall => titleLarge.copyWith(fontSize: _size(28));
  TextStyle get headlineMedium => titleLarge.copyWith(fontSize: _size(36));
  TextStyle get headlineLarge => titleLarge.copyWith(fontSize: _size(40));
  TextStyle get labelSmall => bodySmall.copyWith(fontWeight: FontWeight.w500);
  TextStyle get labelMedium =>
      bodyMedium.copyWith(fontSize: _size(14), fontWeight: FontWeight.w500);
  TextStyle get labelLarge =>
      bodyLarge.copyWith(fontSize: _size(15), fontWeight: FontWeight.w500);
}

class LuminaTheme extends InheritedWidget {
  const LuminaTheme({
    required super.child,
    this.reduceTransparency = false,
    this.highPerformanceMode = true,
    this.brightness = Brightness.light,
    this.darkProgress,
    this.tint,
    this.data = const LuminaThemeData(),
    super.key,
  });
  final bool reduceTransparency;
  final bool highPerformanceMode;
  final Brightness brightness;
  final double? darkProgress;
  final Color? tint;
  final LuminaThemeData data;
  LuminaColors get colors => LuminaColors(
    dark: brightness == Brightness.dark,
    tint: tint,
    neumorphic: data.visualStyle == LuminaVisualStyle.neumorphism,
    darkProgress: darkProgress,
  );
  LuminaTextTheme get textTheme => LuminaTextTheme(colors, data);
  static bool motionReducedOf(BuildContext context) =>
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ||
      of(context).data.motionScale == 0;
  static LuminaTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LuminaTheme>() ??
      LuminaTheme(
        brightness:
            MediaQuery.maybeOf(context)?.platformBrightness ?? Brightness.light,
        child: const SizedBox(),
      );
  @override
  bool updateShouldNotify(LuminaTheme oldWidget) =>
      reduceTransparency != oldWidget.reduceTransparency ||
      highPerformanceMode != oldWidget.highPerformanceMode ||
      brightness != oldWidget.brightness ||
      darkProgress != oldWidget.darkProgress ||
      tint != oldWidget.tint ||
      data != oldWidget.data;
}

/// A single interruptible color transition shared by text, surfaces and rims.
class AnimatedLuminaTheme extends StatelessWidget {
  const AnimatedLuminaTheme({
    required this.brightness,
    required this.child,
    this.highPerformanceMode = true,
    this.data = const LuminaThemeData(),
    super.key,
  });

  final Brightness brightness;
  final bool highPerformanceMode;
  final LuminaThemeData data;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = brightness == Brightness.dark ? 1.0 : 0.0;
    final reduced =
        MediaQuery.disableAnimationsOf(context) || data.motionScale == 0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: target, end: target),
      duration: reduced
          ? Duration.zero
          : Duration(
              microseconds:
                  (LuminaMotion.standard.inMicroseconds * data.motionScale)
                      .round(),
            ),
      curve: Curves.ease,
      child: child,
      builder: (context, progress, child) => LuminaTheme(
        brightness: brightness,
        darkProgress: progress,
        highPerformanceMode: highPerformanceMode,
        data: data,
        child: child!,
      ),
    );
  }
}
