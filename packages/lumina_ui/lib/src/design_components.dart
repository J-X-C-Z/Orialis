import 'dart:ui' as ui;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'lumina_services.dart';
import 'lumina_localizations.dart';
import 'design_tokens.dart';
import 'app_theme.dart';
import 'lumina_motion.dart';
import 'lumina_blur.dart';
export 'lumina_motion.dart';
export 'lumina_blur.dart';

export 'package:flutter/widgets.dart';

export 'design_tokens.dart';
export 'app_theme.dart';
export 'lumina_selection.dart';
part 'lumina_icons.dart';
part 'lumina_inputs.dart';
part 'lumina_overlays.dart';
part 'lumina_material.dart';
part 'lumina_completion.dart';
part 'lumina_patterns.dart';

/// Standard glass: backdrop diffusion, body tint, soft film and contact depth.
/// Accessibility replaces transparency and motion without changing semantics.
enum LuminaSurfaceDepth { normal, raised, recessed }

/// A recess belongs to a material host, never directly to the page canvas.
class _LuminaCardHost extends InheritedWidget {
  const _LuminaCardHost({required super.child});
  @override
  bool updateShouldNotify(_LuminaCardHost oldWidget) => false;
}

/// Space scrollable content needs to clear the floating navigation.
class LuminaNavigationInset extends InheritedWidget {
  const LuminaNavigationInset({
    required this.bottom,
    required super.child,
    super.key,
  });
  final double bottom;
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LuminaNavigationInset>()
          ?.bottom ??
      0;
  @override
  bool updateShouldNotify(LuminaNavigationInset oldWidget) =>
      bottom != oldWidget.bottom;
}

class LuminaSurface extends StatefulWidget {
  const LuminaSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.glass = false,
    this.diffuseGlass = false,
    this.backdrop = false,
    this.depth = LuminaSurfaceDepth.normal,
    this.shoulder = false,
    this.shoulderTitle,
    this.shoulderTrailingSpace = 0,
    this.color,
    this.radius = 24,
    this.onTap,
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glass;

  /// Spreads the cool refracted light across wide capsule controls.
  final bool diffuseGlass;

  /// Opt-in live blur. Reserved for persistent chrome such as the floating
  /// bottom bar — list rows and buttons must leave this off.
  final bool backdrop;
  final LuminaSurfaceDepth depth;

  /// A gently elevated title shelf for large section cards.
  final bool shoulder;
  final String? shoulderTitle;
  final double shoulderTrailingSpace;
  final Color? color;
  final double radius;
  final VoidCallback? onTap;
  @override
  State<LuminaSurface> createState() => _LuminaSurfaceState();
}

class _LuminaSurfaceState extends State<LuminaSurface>
    with TickerProviderStateMixin {
  // Interactive glass needs four springs; plain list rows and high-performance
  // mode skip controller creation entirely so long lists stay cheap.
  LuminaSpring? _spring, _driftX, _driftY, _film;
  Listenable? _glassAnimation;

  LuminaSpring get spring => _spring ??= LuminaSpring(vsync: this);
  LuminaSpring get driftX => _driftX ??= LuminaSpring(vsync: this);
  LuminaSpring get driftY => _driftY ??= LuminaSpring(vsync: this);
  LuminaSpring get film => _film ??= LuminaSpring(vsync: this);

  Listenable get glassAnimation =>
      _glassAnimation ??= Listenable.merge([spring, driftX, driftY, film]);

  Offset contact = Offset.zero;
  @override
  void dispose() {
    _spring?.dispose();
    _driftX?.dispose();
    _driftY?.dispose();
    _film?.dispose();
    super.dispose();
  }

  bool pressed = false, hover = false, focused = false;
  @override
  Widget build(BuildContext context) {
    if (widget.depth == LuminaSurfaceDepth.recessed &&
        context.dependOnInheritedWidgetOfExactType<_LuminaCardHost>() == null) {
      return LuminaSurface(
        depth: LuminaSurfaceDepth.raised,
        radius: widget.radius + 12,
        child: LuminaSurface(
          padding: widget.padding,
          glass: widget.glass,
          diffuseGlass: widget.diffuseGlass,
          backdrop: widget.backdrop,
          depth: widget.depth,
          shoulder: widget.shoulder,
          shoulderTitle: widget.shoulderTitle,
          shoulderTrailingSpace: widget.shoulderTrailingSpace,
          color: widget.color,
          radius: widget.radius,
          onTap: widget.onTap,
          child: widget.child,
        ),
      );
    }
    final media = MediaQuery.maybeOf(context);
    final reduced = LuminaTheme.motionReducedOf(context);
    final contrast = media?.highContrast ?? false;
    final theme = LuminaTheme.of(context);
    final opaque = contrast || theme.reduceTransparency;
    final colors = theme.colors;
    final tint =
        widget.color ??
        switch (widget.depth) {
          LuminaSurfaceDepth.normal => colors.surface,
          LuminaSurfaceDepth.raised => colors.raisedSurface,
          LuminaSurfaceDepth.recessed => colors.recessedSurface,
        };
    final transparent = tint.a == 0 && !widget.glass;
    // Live backdrop blur stays off by default. Opt-in via [LuminaSurface.backdrop]
    // for persistent chrome only (the floating bottom bar). High-performance
    // mode still keeps that single nav blur — it is one saveLayer, not a list.
    final blur = widget.backdrop && widget.glass && !opaque
        ? LuminaBlurPolicy.instance.chrome
        : LuminaBlurConfig.disabled;
    final backdrop = widget.backdrop && widget.glass && !opaque && blur.enabled;
    final blurFilter = backdrop ? LuminaBlurFilters.forConfig(blur) : null;
    final compensation = widget.glass && !opaque ? blur.compensation : 0.0;
    final useSprings = widget.onTap != null && !reduced;
    Widget label = widget.child;
    Widget content = Padding(
      padding: widget.padding * theme.data.spacingScale,
      child: label,
    );
    if (!transparent || focused) {
      final materialChild = content;
      content = LayoutBuilder(
        builder: (context, constraints) {
          double? shoulderWidth;
          if (widget.shoulderTitle != null && constraints.hasBoundedWidth) {
            final painter =
                TextPainter(
                  text: TextSpan(
                    text: widget.shoulderTitle,
                    style: theme.textTheme.cardTitle,
                  ),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout(
                  maxWidth: math.max(
                    1,
                    constraints.maxWidth - 32 - widget.shoulderTrailingSpace,
                  ),
                );
            final lines = painter.computeLineMetrics();
            shoulderWidth = 16 + (lines.isEmpty ? 0 : lines.first.width) + 28;
            painter.dispose();
          }
          return RepaintBoundary(
            child: CustomPaint(
              painter: _LuminaMaterial(
                colors: colors,
                tint: transparent
                    ? colors.surface
                    : widget.glass && !opaque
                    // Thin frost: keep tint low so the blur actually reads.
                    ? tint.withValues(alpha: backdrop ? .22 : .58)
                    : tint,
                glass: widget.glass && !opaque,
                diffuseGlass: widget.diffuseGlass,
                radius: widget.radius >= LuminaControlSize.capsuleRadius
                    ? widget.radius
                    : widget.radius * theme.data.radiusScale,
                depth: widget.depth,
                shoulder: widget.shoulder,
                shoulderWidth: shoulderWidth,
                contrast: contrast,
                focused: focused,
                pressed: pressed,
                cheapShadow: theme.highPerformanceMode,
                blurCompensation: compensation,
              ),
              child: materialChild,
            ),
          );
        },
      );
    }
    if (!widget.glass &&
        !transparent &&
        widget.depth != LuminaSurfaceDepth.recessed) {
      content = _LuminaCardHost(child: content);
    }
    if (backdrop && blurFilter != null) {
      // Clip the backdrop only, allowing the material shadow to breathe.
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: BackdropFilter(
                filter: blurFilter,
                child: const ColoredBox(
                  // Translucent veil — without this the filter output can
                  // read as "no blur" when the backdrop is near-solid.
                  color: Color(0x24FFFFFF),
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
          content,
        ],
      );
    }
    if (widget.onTap == null) return content;
    return Semantics(
      button: true,
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => focused = v),
        onShowHoverHighlight: (v) => setState(() => hover = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap!();
              return null;
            },
          ),
        },
        child: MouseRegion(
          onHover: (event) {
            contact = event.localPosition;
          },
          onExit: (_) {},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (d) {
              contact = d.localPosition;
              setState(() => pressed = true);
              if (!useSprings) return;
              spring.settle(1, reducedMotion: reduced);
            },
            onTapUp: (_) {
              setState(() => pressed = false);
              if (!useSprings) return;
              spring.settle(0, reducedMotion: reduced);
            },
            onTapCancel: () {
              setState(() => pressed = false);
              if (!useSprings) return;
              spring.settle(0, reducedMotion: reduced);
            },
            child: useSprings
                ? AnimatedBuilder(
                    animation: _spring ?? kAlwaysDismissedAnimation,
                    child: content,
                    builder: (context, child) {
                      final offset = reduced
                          ? Offset.zero
                          : Offset(
                              0,
                              (_spring?.value ?? 0) * theme.data.motionScale,
                            );
                      final pressure = widget.glass
                          ? (_spring?.value ?? 0).clamp(-.15, 1.0) *
                                theme.data.motionScale
                          : 0.0;
                      Widget body = child!;
                      if (pressure != 0) {
                        body = Transform.scale(
                          scaleX: 1 + pressure * .035,
                          scaleY: 1 - pressure * .065,
                          child: body,
                        );
                      }
                      if (offset != Offset.zero) {
                        body = Transform.translate(offset: offset, child: body);
                      }
                      return body;
                    },
                  )
                : content,
          ),
        ),
      ),
    );
  }
}

class LuminaButton extends StatelessWidget {
  const LuminaButton({
    required this.onPressed,
    required this.child,
    this.icon,
    this.primary = true,
    super.key,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final bool primary;
  @override
  Widget build(BuildContext context) => Semantics(
    enabled: onPressed != null,
    child: Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: LuminaSurface(
        glass: true,
        radius: LuminaControlSize.capsuleRadius,
        onTap: onPressed,
        color: primary
            ? LuminaTheme.of(context).colors.accentSoft
            : LuminaTheme.of(context).colors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.labelMedium,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[icon!, const SizedBox(width: 8)],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class LuminaIconButton extends StatelessWidget {
  const LuminaIconButton({
    required this.onPressed,
    required this.icon,
    this.tooltip,
    super.key,
  });
  final VoidCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => Semantics(
    label: tooltip,
    button: true,
    enabled: onPressed != null,
    child: Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: LuminaSurface(
        onTap: onPressed,
        glass: true,
        radius: LuminaControlSize.capsuleRadius,
        padding: EdgeInsets.zero,
        child: SizedBox.square(
          dimension: LuminaControlSize.minimum,
          child: Center(child: icon),
        ),
      ),
    ),
  );
}

class LuminaProgress extends StatefulWidget {
  const LuminaProgress({this.value, super.key});
  final double? value;
  @override
  State<LuminaProgress> createState() => _LuminaProgressState();
}

class _LuminaProgressState extends State<LuminaProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  void _updateAnimation() {
    if (LuminaTheme.motionReducedOf(context) || widget.value != null) {
      controller.stop();
      controller.value = 0;
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(LuminaProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: LuminaLocalizations.of(context).loading,
    value: widget.value == null ? null : '${(widget.value! * 100).round()}%',
    child: SizedBox(
      width: 22,
      height: 22,
      // Isolate the spinner so its 60fps tick cannot dirty neighboring rows.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            painter: _ProgressPainter(
              widget.value,
              LuminaTheme.motionReducedOf(context) ? 0 : controller.value,
              LuminaTheme.of(context).colors,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.value, this.phase, this.colors);
  final LuminaColors colors;
  final double? value;
  final double phase;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = colors.outline;
    canvas.drawOval(r, p);
    p.color = colors.accent;
    canvas.drawArc(r, phase * 6.283 - 1.57, (value ?? 0.28) * 6.283, false, p);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.phase != phase ||
      old.value != value ||
      old.colors.dark != colors.dark;
}

class LuminaPageScaffold extends StatelessWidget {
  const LuminaPageScaffold({
    required this.title,
    required this.body,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottomActions,
    this.floatingActionButton,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget body;
  final Widget? bottomActions, floatingActionButton;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: LuminaTheme.of(context).colors.paper,
    child: SafeArea(
      bottom: false,
      child: Column(
        children: [
          LuminaTopBar(
            title: title,
            subtitle: subtitle,
            leading: leading,
            actions: actions,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      padding: EdgeInsets.only(
                        bottom:
                            LuminaNavigationInset.of(context) +
                            MediaQuery.paddingOf(context).bottom,
                      ),
                    ),
                    child: Padding(padding: padding, child: body),
                  ),
                ),
                if (floatingActionButton != null)
                  Positioned(
                    right: 20,
                    bottom:
                        20 +
                        LuminaNavigationInset.of(context) +
                        MediaQuery.paddingOf(context).bottom,
                    child: floatingActionButton!,
                  ),
              ],
            ),
          ),
          ?bottomActions,
        ],
      ),
    ),
  );
}

class LuminaTopBar extends StatelessWidget {
  const LuminaTopBar({
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LuminaSurface(
    radius: 28,
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: LuminaControlSize.topBarContentHeight,
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: LuminaTheme.of(context).textTheme.titleLarge,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          ...actions.map(
            (a) => Padding(padding: const EdgeInsets.only(left: 8), child: a),
          ),
        ],
      ),
    ),
  );
}

class LuminaListRow extends StatelessWidget {
  const LuminaListRow({
    required this.title,
    this.subtitle,
    this.detail,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.depth = LuminaSurfaceDepth.normal,
    this.enabled = true,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? detail;
  final Widget? leading, trailing;
  final VoidCallback? onTap;
  final bool selected, enabled;
  final LuminaSurfaceDepth depth;
  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : .5,
    child: LuminaSurface(
      onTap: enabled ? onTap : null,
      depth: depth,
      glass:
          onTap != null &&
          context.dependOnInheritedWidgetOfExactType<_LuminaSheetScope>() !=
              null,
      color: selected ? LuminaTheme.of(context).colors.accentSoft : null,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: depth == LuminaSurfaceDepth.recessed
                      ? LuminaTheme.of(context).textTheme.recessedTitle
                      : LuminaTheme.of(context).textTheme.titleSmall,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
                ],
                ?detail,
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    ),
  );
}

/// Shared heading for large content cards. The text starts at the same
/// top-left inset even when the opposite side has a tall action control.
class LuminaCardHeader extends StatelessWidget {
  const LuminaCardHeader({
    required this.title,
    this.trailing,
    this.onTitleTap,
    this.expanded,
    super.key,
  });
  final String title;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final bool? expanded;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Semantics(
          header: true,
          expanded: expanded,
          child: LuminaTap(
            onTap: onTitleTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: onTitleTap == null ? 0 : LuminaControlSize.minimum,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: LuminaTheme.of(context).textTheme.cardTitle,
                    ),
                  ),
                  if (expanded != null) ...[
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: expanded! ? .25 : 0,
                      duration: LuminaTheme.motionReducedOf(context)
                          ? Duration.zero
                          : LuminaMotion.standard,
                      curve: luminaEaseOut,
                      child: const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: LuminaIcon(LuminaIcons.chevronRight, size: 18),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      ?trailing,
    ],
  );
}

class LuminaSection extends StatelessWidget {
  const LuminaSection({
    required this.title,
    required this.child,
    this.trailing,
    this.raised = false,
    this.padding = LuminaCardMetrics.contentInsets,
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool raised;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final header = raised
        ? LuminaCardHeader(title: title, trailing: trailing)
        : Row(
            children: [
              Expanded(child: LuminaSectionHeader(title: title)),
              ?trailing,
            ],
          );
    if (raised) {
      return LuminaCollapsibleCard(
        storageId: 'section:$title',
        title: title,
        trailing: trailing,
        padding: padding,
        child: child,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        LuminaSurface(padding: padding, child: child),
      ],
    );
  }
}

class LuminaSectionHeader extends StatelessWidget {
  const LuminaSectionHeader({required this.title, super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(title, style: LuminaTheme.of(context).textTheme.cardTitle),
  );
}

class LuminaBottomActionBar extends StatelessWidget {
  const LuminaBottomActionBar({
    required this.primary,
    this.secondary,
    super.key,
  });
  final Widget primary;
  final Widget? secondary;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Row(
      children: [
        if (secondary != null) ...[
          Expanded(child: secondary!),
          const SizedBox(width: 10),
        ],
        Expanded(child: primary),
      ],
    ),
  );
}

class LuminaEmptyState extends StatelessWidget {
  const LuminaEmptyState({required this.text, this.card = true, super.key});
  final String text;
  final bool card;
  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: LuminaTheme.of(context).textTheme.bodyMedium
            .copyWith(color: LuminaTheme.of(context).colors.muted),
      ),
    );
    return card ? LuminaSurface(child: content) : Center(child: content);
  }
}

class LuminaChatBubble extends StatelessWidget {
  const LuminaChatBubble({
    required this.isUser,
    required this.child,
    super.key,
  });
  final bool isUser;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final maxBubbleWidth = constraints.maxWidth >= 900
          ? LuminaChatMetrics.desktopBubbleMaxWidth
          : LuminaChatMetrics.bubbleMaxWidth;
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth.isFinite
                ? (constraints.maxWidth * .80).clamp(0, maxBubbleWidth)
                : maxBubbleWidth,
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: LuminaSurface(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            color: isUser ? LuminaTheme.of(context).colors.accentSoft : null,
            radius: 22,
            child: child,
          ),
        ),
      );
    },
  );
}
