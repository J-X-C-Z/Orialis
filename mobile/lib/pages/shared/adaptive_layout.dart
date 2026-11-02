import 'package:flutter/widgets.dart';

/// Window layout only; account, sync and route behavior remain mobile.
class OrialisAdaptiveLayout extends InheritedWidget {
  const OrialisAdaptiveLayout({
    required this.wide,
    required this.tablet,
    required this.navigationWidth,
    required super.child,
    super.key,
  });

  final bool wide, tablet;
  final double navigationWidth;

  static OrialisAdaptiveLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrialisAdaptiveLayout>();

  @override
  bool updateShouldNotify(OrialisAdaptiveLayout oldWidget) =>
      wide != oldWidget.wide ||
      tablet != oldWidget.tablet ||
      navigationWidth != oldWidget.navigationWidth;
}
