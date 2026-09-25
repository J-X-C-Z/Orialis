import 'package:flutter/widgets.dart';

class LuminaBaseColors {
  static const ink = Color(0xFF152232),
      paper = Color(0xFFE9EEF4),
      surface = Color(0xFFF2F5F8),
      accent = Color(0xFF3978D0),
      accentSoft = Color(0xFFDCE7F5),
      muted = Color(0xFF637183),
      danger = Color(0xFFAC4545),
      outline = Color(0xFFD8E0E5);
}

class LuminaSpacing {
  static const page = 20.0,
      pageTop = 12.0,
      section = 24.0,
      item = 14.0,
      compact = 8.0,
      tight = 6.0,
      emptyState = 24.0,
      controlGap = 8.0;
}

class LuminaRadius {
  static const card = 24.0, control = 18.0, attachment = 14.0;
}

/// Large information cards share one heading origin and type hierarchy.
/// Their inset rows use a quieter title; pill controls use full radius.
class LuminaCardMetrics {
  static const contentInsets = EdgeInsets.all(16);
  static const titleToContent = 12.0;
}

class LuminaControlSize {
  static const minimum = 48.0;
  static const capsuleRadius = 999.0;
  static const topBarContentHeight = 56.0;
}

class LuminaIconSize {
  static const compact = 17.0, control = 24.0;
}

class LuminaChatMetrics {
  static const bubbleMaxWidth = 360.0,
      bubbleHorizontalPadding = 17.0,
      bubbleVerticalPadding = 14.0,
      bubbleBottomGap = 12.0,
      attachmentTopGap = 8.0,
      imageWidth = 270.0,
      imageHeight = 180.0;
}

class LuminaMotion {
  static const fast = Duration(milliseconds: 140),
      page = Duration(milliseconds: 180),
      standard = Duration(milliseconds: 220),
      fluid = Duration(milliseconds: 420);
}
