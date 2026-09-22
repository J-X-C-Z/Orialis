import 'package:flutter/widgets.dart';

class AppColors {
  static const ink = Color(0xFF202D34),
      paper = Color(0xFFEEF2F4),
      surface = Color(0xFFFAFCFD),
      accent = Color(0xFF476F82),
      accentSoft = Color(0xFFE0EBEF),
      muted = Color(0xFF62727C),
      danger = Color(0xFFAC4545),
      outline = Color(0xFFD8E0E5);
}

class AppSpacing {
  static const page = 20.0,
      pageTop = 12.0,
      section = 24.0,
      item = 14.0,
      compact = 8.0,
      tight = 6.0,
      emptyState = 24.0,
      controlGap = 8.0;
}

class AppRadius {
  static const card = 24.0, control = 18.0, attachment = 14.0;
}

class AppIconSize {
  static const compact = 17.0, control = 24.0;
}

class AppChatMetrics {
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
      standard = Duration(milliseconds: 220),
      fluid = Duration(milliseconds: 420);
}
