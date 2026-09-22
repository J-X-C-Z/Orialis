import 'package:flutter/widgets.dart';
import 'design_tokens.dart';

class LuminaColors {
  const LuminaColors({this.dark = false});
  final bool dark;
  Color get ink => dark ? const Color(0xFFECF1F4) : AppColors.ink;
  Color get paper => dark ? const Color(0xFF121B23) : AppColors.paper;
  Color get canvas => paper;
  Color get surface => dark ? const Color(0xFF202C36) : AppColors.surface;
  Color get accent => dark ? const Color(0xFF9EC4D5) : AppColors.accent;
  Color get accentSoft => dark ? const Color(0xFF314B59) : AppColors.accentSoft;
  Color get muted => dark ? const Color(0xFFA6B6C2) : AppColors.muted;
  Color get danger => dark ? const Color(0xFFFFA6A1) : AppColors.danger;
  Color get outline => dark ? const Color(0xFF42515F) : AppColors.outline;
}

class LuminaTextTheme {
  const LuminaTextTheme([this.colors = const LuminaColors()]);
  final LuminaColors colors;
  TextStyle get bodySmall =>
      TextStyle(fontSize: 12, height: 1.5, color: colors.muted);
  TextStyle get bodyMedium =>
      TextStyle(fontSize: 14, height: 1.5, color: colors.ink);
  TextStyle get bodyLarge =>
      TextStyle(fontSize: 16, height: 1.5, color: colors.ink);
  TextStyle get titleSmall => bodyMedium.copyWith(fontWeight: FontWeight.w600);
  TextStyle get titleMedium => bodyLarge.copyWith(fontWeight: FontWeight.w600);
  TextStyle get titleLarge => TextStyle(
    fontSize: 23,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: colors.ink,
    letterSpacing: -.6,
  );
  TextStyle get headlineSmall => titleLarge.copyWith(fontSize: 28);
  TextStyle get headlineMedium => titleLarge.copyWith(fontSize: 32);
  TextStyle get headlineLarge => titleLarge.copyWith(fontSize: 40);
  TextStyle get labelSmall => bodySmall.copyWith(fontWeight: FontWeight.w600);
  TextStyle get labelMedium => bodyMedium.copyWith(fontWeight: FontWeight.w600);
  TextStyle get labelLarge => bodyLarge.copyWith(fontWeight: FontWeight.w600);
}

class LuminaTheme extends InheritedWidget {
  const LuminaTheme({
    required super.child,
    this.reduceTransparency = false,
    this.brightness = Brightness.light,
    super.key,
  });
  final bool reduceTransparency;
  final Brightness brightness;
  LuminaColors get colors => LuminaColors(dark: brightness == Brightness.dark);
  LuminaTextTheme get textTheme => LuminaTextTheme(colors);
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
      brightness != oldWidget.brightness;
}
