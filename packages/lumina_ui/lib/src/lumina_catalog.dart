import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';

import 'dart:math' as math;

import 'design_components.dart';
import 'lumina_localizations.dart';

part 'lumina_catalog_feedback.dart';
part 'lumina_catalog_navigation.dart';
part 'lumina_catalog_selection.dart';

/// Material 3 interoperability layer. Flutter retains its established focus,
/// keyboard, semantics and accessibility behavior; Lumina supplies the skin.
class LuminaMaterialBridge extends StatelessWidget {
  const LuminaMaterialBridge({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lumina = LuminaTheme.of(context);
    final c = lumina.colors;
    final dark = lumina.brightness == Brightness.dark;
    final radius = lumina.data.radiusScale;
    final controlShape = m.RoundedRectangleBorder(
      borderRadius: m.BorderRadius.circular(LuminaRadius.control * radius),
    );
    final cardShape = m.RoundedRectangleBorder(
      borderRadius: m.BorderRadius.circular(LuminaRadius.card * radius),
    );
    final scheme =
        m.ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: lumina.brightness,
          surface: c.surface,
        ).copyWith(
          primary: c.accent,
          onPrimary: c.paper,
          surface: c.surface,
          onSurface: c.ink,
          outline: c.outline,
          error: c.danger,
        );
    return m.Theme(
      data: m.ThemeData(
        useMaterial3: true,
        brightness: lumina.brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: c.canvas,
        dividerColor: c.outline,
        cardColor: c.surface,
        textTheme: m.ThemeData(brightness: lumina.brightness).textTheme.apply(
          bodyColor: c.ink,
          displayColor: c.ink,
          fontFamily: lumina.data.fontFamily,
        ),
        splashFactory: dark
            ? m.InkRipple.splashFactory
            : m.InkSparkle.splashFactory,
        cardTheme: m.CardThemeData(
          color: c.surface,
          elevation: 0,
          shape: m.RoundedRectangleBorder(
            side: m.BorderSide(color: c.outline),
            borderRadius: m.BorderRadius.circular(LuminaRadius.card * radius),
          ),
        ),
        dialogTheme: m.DialogThemeData(
          backgroundColor: c.raisedSurface,
          shape: m.RoundedRectangleBorder(
            borderRadius: m.BorderRadius.circular(28 * radius),
          ),
        ),
        floatingActionButtonTheme: m.FloatingActionButtonThemeData(
          backgroundColor: c.accentSoft,
          foregroundColor: c.ink,
          elevation: 2,
          shape: controlShape,
        ),
        badgeTheme: m.BadgeThemeData(
          backgroundColor: c.accent,
          textColor: c.paper,
          textStyle: lumina.textTheme.labelSmall,
        ),
        progressIndicatorTheme: m.ProgressIndicatorThemeData(
          color: c.accent,
          linearTrackColor: c.recessedSurface,
          borderRadius: m.BorderRadius.circular(LuminaRadius.control * radius),
        ),
        navigationBarTheme: m.NavigationBarThemeData(
          backgroundColor: c.raisedSurface,
          indicatorColor: c.accentSoft,
          height: 72,
          elevation: 0,
          labelTextStyle: m.WidgetStatePropertyAll(lumina.textTheme.labelSmall),
          iconTheme: m.WidgetStatePropertyAll(m.IconThemeData(color: c.ink)),
        ),
        navigationRailTheme: m.NavigationRailThemeData(
          backgroundColor: c.raisedSurface,
          indicatorColor: c.accentSoft,
          selectedLabelTextStyle: lumina.textTheme.labelSmall,
          unselectedLabelTextStyle: lumina.textTheme.labelSmall.copyWith(
            color: c.muted,
          ),
        ),
        navigationDrawerTheme: m.NavigationDrawerThemeData(
          backgroundColor: c.raisedSurface,
          indicatorColor: c.accentSoft,
          tileHeight: LuminaControlSize.minimum,
        ),
        bottomAppBarTheme: m.BottomAppBarThemeData(
          color: c.raisedSurface,
          elevation: 0,
          height: 64,
        ),
        tabBarTheme: m.TabBarThemeData(
          labelColor: c.ink,
          unselectedLabelColor: c.muted,
          indicatorColor: c.accent,
          dividerColor: c.outline,
          labelStyle: lumina.textTheme.labelMedium,
        ),
        chipTheme: m.ChipThemeData(
          backgroundColor: c.surface,
          selectedColor: c.accentSoft,
          disabledColor: c.recessedSurface,
          labelStyle: lumina.textTheme.labelMedium,
          side: m.BorderSide(color: c.outline),
          shape: controlShape,
        ),
        segmentedButtonTheme: m.SegmentedButtonThemeData(
          style: m.ButtonStyle(
            backgroundColor: m.WidgetStateProperty.resolveWith(
              (states) => states.contains(m.WidgetState.selected)
                  ? c.accentSoft
                  : c.recessedSurface,
            ),
            foregroundColor: m.WidgetStatePropertyAll(c.ink),
            side: m.WidgetStatePropertyAll(m.BorderSide(color: c.outline)),
            shape: m.WidgetStatePropertyAll(controlShape),
            textStyle: m.WidgetStatePropertyAll(lumina.textTheme.labelMedium),
          ),
        ),
        sliderTheme: m.SliderThemeData(
          activeTrackColor: c.accent,
          inactiveTrackColor: c.recessedSurface,
          thumbColor: c.raisedSurface,
          overlayColor: c.accentSoft,
          valueIndicatorColor: c.raisedSurface,
          valueIndicatorTextStyle: lumina.textTheme.labelSmall,
        ),
        menuTheme: m.MenuThemeData(
          style: m.MenuStyle(
            backgroundColor: m.WidgetStatePropertyAll(c.raisedSurface),
            surfaceTintColor: const m.WidgetStatePropertyAll(
              m.Colors.transparent,
            ),
            shape: m.WidgetStatePropertyAll(cardShape),
          ),
        ),
        menuButtonTheme: m.MenuButtonThemeData(
          style: m.ButtonStyle(
            foregroundColor: m.WidgetStatePropertyAll(c.ink),
            textStyle: m.WidgetStatePropertyAll(lumina.textTheme.bodyMedium),
          ),
        ),
        listTileTheme: m.ListTileThemeData(
          tileColor: c.surface,
          selectedTileColor: c.accentSoft,
          iconColor: c.muted,
          textColor: c.ink,
          shape: controlShape,
          contentPadding: const m.EdgeInsets.symmetric(horizontal: 16),
        ),
        tooltipTheme: m.TooltipThemeData(
          decoration: m.BoxDecoration(
            color: c.raisedSurface,
            border: m.Border.all(color: c.outline),
            borderRadius: m.BorderRadius.circular(
              LuminaRadius.attachment * radius,
            ),
          ),
          textStyle: lumina.textTheme.labelSmall,
        ),
      ),
      child: child,
    );
  }
}

/// Explicit appearance choice; persistence and effective system brightness are
/// owned by the host application.
class LuminaThemeModeSelector extends StatelessWidget {
  const LuminaThemeModeSelector({
    required this.value,
    required this.onChanged,
    this.systemLabel,
    this.lightLabel,
    this.darkLabel,
    super.key,
  });

  final m.ThemeMode value;
  final ValueChanged<m.ThemeMode> onChanged;
  final String? systemLabel, lightLabel, darkLabel;

  @override
  Widget build(BuildContext context) {
    final chinese =
        m.Localizations.maybeLocaleOf(context)?.languageCode != 'en';
    return LuminaSegmented<m.ThemeMode>(
      transparent: true,
      items: {
        m.ThemeMode.system: systemLabel ?? (chinese ? '跟随系统' : 'System'),
        m.ThemeMode.light: lightLabel ?? (chinese ? '浅色' : 'Light'),
        m.ThemeMode.dark: darkLabel ?? (chinese ? '深色' : 'Dark'),
      },
      value: value,
      onChanged: onChanged,
    );
  }
}
