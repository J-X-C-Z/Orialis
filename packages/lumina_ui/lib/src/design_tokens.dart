import 'package:flutter/widgets.dart';

import 'lumina_tokens_generated.dart';

class LuminaBaseColors {
  static const ink = LuminaTokenLight.ink,
      paper = LuminaTokenLight.paper,
      surface = LuminaTokenLight.surface,
      accent = LuminaTokenLight.accent,
      accentSoft = LuminaTokenLight.accentSoft,
      muted = LuminaTokenLight.muted,
      danger = LuminaTokenLight.danger,
      outline = LuminaTokenLight.outline;
}

class LuminaSpacing {
  static const page = LuminaTokenSpacing.page,
      pageTop = LuminaTokenSpacing.pageTop,
      section = LuminaTokenSpacing.section,
      item = LuminaTokenSpacing.item,
      compact = LuminaTokenSpacing.compact,
      tight = LuminaTokenSpacing.tight,
      emptyState = LuminaTokenSpacing.emptyState,
      controlGap = LuminaTokenSpacing.controlGap;
}

class LuminaRadius {
  static const card = LuminaTokenRadius.card,
      control = LuminaTokenRadius.control,
      attachment = LuminaTokenRadius.attachment;
}

/// Large information cards share one heading origin and type hierarchy.
/// Their inset rows use a quieter title; pill controls use full radius.
class LuminaCardMetrics {
  static const contentInsets = EdgeInsets.all(16);
  static const titleToContent = 12.0;
}

class LuminaControlSize {
  static const minimum = LuminaTokenSize.minimumControl;
  static const capsuleRadius = LuminaTokenRadius.capsule;
  static const topBarContentHeight = LuminaTokenSize.topBarContent;
}

class LuminaIconSize {
  static const compact = LuminaTokenSize.compactIcon,
      control = LuminaTokenSize.controlIcon;
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
  static const fast = Duration(milliseconds: LuminaTokenMotion.fast),
      page = Duration(milliseconds: LuminaTokenMotion.page),
      standard = Duration(milliseconds: LuminaTokenMotion.standard),
      fluid = Duration(milliseconds: LuminaTokenMotion.fluid);
}
