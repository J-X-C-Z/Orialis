import 'package:flutter/widgets.dart';

import 'design_tokens.dart';

/// Central overrides; defaults reproduce the original Lumina design.
@immutable
class LuminaThemeData {
  const LuminaThemeData({
    this.fontFamily = 'sans-serif',
    this.fontScale = 1,
    this.spacingScale = 1,
    this.radiusScale = 1,
    this.motionScale = 1,
  }) : assert(fontScale > 0),
       assert(spacingScale >= .8),
       assert(radiusScale > 0),
       assert(motionScale >= 0 && motionScale <= 1);
  final String? fontFamily;
  final double fontScale, spacingScale, radiusScale, motionScale;
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
  LuminaColors colors({bool dark = false}) =>
      LuminaColors(dark: dark, tint: tint);
}

class LuminaColors {
  const LuminaColors({this.dark = false, this.tint});
  final bool dark;
  final Color? tint;
  Color _tone(Color base, double amount) =>
      tint == null ? base : Color.lerp(base, tint, amount)!;
  Color get ink => dark ? const Color(0xFFECF1F4) : LuminaBaseColors.ink;
  Color get paper => dark ? const Color(0xFF121B23) : LuminaBaseColors.paper;
  Color get canvas => paper;
  Color get surface =>
      _tone(dark ? const Color(0xFF202C36) : LuminaBaseColors.surface, .10);
  Color get raisedSurface =>
      _tone(dark ? const Color(0xFF2A3944) : const Color(0xFFEDF2F7), .13);
  Color get recessedSurface =>
      _tone(dark ? const Color(0xFF18232C) : const Color(0xFFE1E8F1), .23);
  Color get accent => tint == null
      ? (dark ? const Color(0xFF9EC4D5) : LuminaBaseColors.accent)
      : Color.lerp(
          tint,
          dark ? const Color(0xFFFFFFFF) : LuminaBaseColors.ink,
          dark ? .40 : .25,
        )!;
  Color get accentSoft =>
      _tone(dark ? const Color(0xFF314B59) : LuminaBaseColors.accentSoft, .30);
  Color get muted => dark ? const Color(0xFFA6B6C2) : LuminaBaseColors.muted;
  Color get danger => dark ? const Color(0xFFFFA6A1) : LuminaBaseColors.danger;
  Color get outline =>
      dark ? const Color(0xFF42515F) : LuminaBaseColors.outline;
}

class LuminaTextTheme {
  const LuminaTextTheme([
    this.colors = const LuminaColors(),
    this.data = const LuminaThemeData(),
  ]);
  final LuminaColors colors;
  final LuminaThemeData data;
  double _size(double base) => base * data.fontScale;
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
    this.tint,
    this.data = const LuminaThemeData(),
    super.key,
  });
  final bool reduceTransparency;
  final bool highPerformanceMode;
  final Brightness brightness;
  final Color? tint;
  final LuminaThemeData data;
  LuminaColors get colors =>
      LuminaColors(dark: brightness == Brightness.dark, tint: tint);
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
      tint != oldWidget.tint ||
      data != oldWidget.data;
}
