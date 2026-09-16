import 'package:flutter/material.dart';

/// Brand and semantic colors. Pages should use these semantic roles instead
/// of introducing one-off colors in their own widget trees.
class AppColors {
  static const ink = Color(0xFF14201F);
  static const paper = Color(0xFFF7F7F3);
  static const surface = Colors.white;
  static const accent = Color(0xFF287A70);
  static const accentSoft = Color(0xFFDDEEE8);
  static const muted = Color(0xFF687572);
  static const danger = Color(0xFFB34D48);
  static const outline = Color(0xFFE0E7E2);
}

class AppSpacing {
  static const page = 20.0;
  static const pageTop = 8.0;
  static const section = 24.0;
  static const item = 12.0;
  static const compact = 8.0;
  static const tight = 6.0;
  static const emptyState = 18.0;
  static const controlGap = 8.0;
}

class AppRadius {
  static const card = 18.0;
  static const control = 12.0;
  static const attachment = 10.0;
}

class AppIconSize {
  static const compact = 17.0;
  static const control = 24.0;
}

class AppChatMetrics {
  static const bubbleMaxWidth = 320.0;
  static const bubbleHorizontalPadding = 15.0;
  static const bubbleVerticalPadding = 11.0;
  static const bubbleBottomGap = 10.0;
  static const attachmentTopGap = 8.0;
  static const imageWidth = 270.0;
  static const imageHeight = 180.0;
}
