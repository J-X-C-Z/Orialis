import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'design_tokens.dart';
import 'app_theme.dart';
import 'lumina_motion.dart';
export 'lumina_motion.dart';
export 'package:flutter/widgets.dart';
export 'design_tokens.dart';
export 'app_theme.dart';
export 'lumina_selection.dart';
part 'lumina_icons.dart';
part 'lumina_inputs.dart';
part 'lumina_overlays.dart';

/// Standard glass: backdrop diffusion, body tint, soft film and contact depth.
/// Accessibility replaces transparency and motion without changing semantics.
class LuminaSurface extends StatefulWidget {
  const LuminaSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.glass = false,
    this.color,
    this.radius = 24,
    this.onTap,
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glass;
  final Color? color;
  final double radius;
  final VoidCallback? onTap;
  @override
  State<LuminaSurface> createState() => _LuminaSurfaceState();
}

class _LuminaSurfaceState extends State<LuminaSurface>
    with TickerProviderStateMixin {
  late final spring = LuminaSpring(vsync: this);
  late final driftX = LuminaSpring(vsync: this);
  late final driftY = LuminaSpring(vsync: this);
  late final film = LuminaSpring(vsync: this);
  Offset contact = Offset.zero;
  @override
  void dispose() {
    spring.dispose();
    driftX.dispose();
    driftY.dispose();
    film.dispose();
    super.dispose();
  }

  bool pressed = false, hover = false, focused = false;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final reduced = media?.disableAnimations ?? false;
    final contrast = media?.highContrast ?? false;
    final opaque = contrast || LuminaTheme.of(context).reduceTransparency;
    final colors = LuminaTheme.of(context).colors;
    final tint = widget.color ?? colors.surface;
    Widget content = AnimatedContainer(
      duration: reduced ? Duration.zero : LuminaMotion.fast,
      padding: widget.padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(
              tint,
              colors.surface,
              .12,
            )!.withValues(alpha: widget.glass && !opaque ? 0.86 : tint.a),
            tint.withValues(alpha: widget.glass && !opaque ? 0.63 : tint.a),
          ],
        ),
        border: Border.all(
          color: focused
              ? LuminaTheme.of(context).colors.accent
              : contrast
              ? LuminaTheme.of(context).colors.muted
              : LuminaTheme.of(context).colors.outline.withValues(alpha: .75),
          width: focused ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: LuminaTheme.of(
              context,
            ).colors.ink.withValues(alpha: pressed ? 0.025 : .045),
            blurRadius: widget.glass ? 20 : 12,
            offset: Offset(0, pressed ? 1 : 4),
          ),
          if (widget.glass && !opaque)
            const BoxShadow(
              color: Color(0x30FFFFFF),
              blurRadius: 1,
              offset: Offset(0, -1),
            ),
        ],
      ),
      child: widget.child,
    );
    if (widget.glass && !opaque) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: content,
        ),
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
            if (!widget.glass || reduced) return;
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            contact = event.localPosition;
            driftX.settle(
              ((contact.dx - box.size.width / 2) * .035).clamp(-3, 3),
            );
            driftY.settle(
              ((contact.dy - box.size.height / 2) * .035).clamp(-2, 2),
            );
            film.settle(.5);
          },
          onExit: (_) {
            driftX.settle(0, reducedMotion: reduced);
            driftY.settle(0, reducedMotion: reduced);
            film.settle(0, reducedMotion: reduced);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (d) {
              contact = d.localPosition;
              setState(() => pressed = true);
              spring.settle(1, reducedMotion: reduced);
              film.settle(1, reducedMotion: reduced);
            },
            onTapUp: (_) {
              setState(() => pressed = false);
              spring.settle(0, reducedMotion: reduced);
              film.settle(0, reducedMotion: reduced);
            },
            onTapCancel: () {
              setState(() => pressed = false);
              spring.settle(0, reducedMotion: reduced);
              film.settle(0, reducedMotion: reduced);
            },
            child: AnimatedBuilder(
              animation: Listenable.merge([spring, driftX, driftY, film]),
              child: content,
              builder: (context, child) => Transform.translate(
                offset: reduced
                    ? Offset.zero
                    : Offset(driftX.value, driftY.value),
                child: Transform.scale(
                  scale: widget.glass && !reduced ? 1 - spring.value * .025 : 1,
                  child: Stack(
                    children: [
                      child!,
                      if (widget.glass && !opaque && !reduced)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _GlassFilm(
                                contact,
                                film.value,
                                colors.accent,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
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
        radius: 18,
        onTap: onPressed,
        color: primary
            ? LuminaTheme.of(context).colors.accentSoft
            : LuminaTheme.of(context).colors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
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
        radius: 16,
        padding: const EdgeInsets.all(12),
        child: icon,
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
    if (MediaQuery.maybeOf(context)?.disableAnimations == true ||
        widget.value != null) {
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
    label: '加载中',
    value: widget.value == null ? null : '${(widget.value! * 100).round()}%',
    child: SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => CustomPaint(
          painter: _ProgressPainter(
            widget.value,
            MediaQuery.maybeOf(context)?.disableAnimations == true
                ? 0
                : controller.value,
            LuminaTheme.of(context).colors,
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

class OrialisPageScaffold extends StatelessWidget {
  const OrialisPageScaffold({
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
      child: Column(
        children: [
          OrialisTopBar(
            title: title,
            subtitle: subtitle,
            leading: leading,
            actions: actions,
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(padding: padding, child: body),
                ),
                if (floatingActionButton != null)
                  Positioned(
                    right: 20,
                    bottom: 20,
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

class OrialisTopBar extends StatelessWidget {
  const OrialisTopBar({
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    child: Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: LuminaTheme.of(context).textTheme.titleLarge),
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
  );
}

class OrialisListRow extends StatelessWidget {
  const OrialisListRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.enabled = true,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? leading, trailing;
  final VoidCallback? onTap;
  final bool selected, enabled;
  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : .5,
    child: LuminaSurface(
      onTap: enabled ? onTap : null,
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
                  style: LuminaTheme.of(context).textTheme.titleSmall,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    ),
  );
}

class OrialisSection extends StatelessWidget {
  const OrialisSection({
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: OrialisSectionHeader(title: title)),
          ?trailing,
        ],
      ),
      LuminaSurface(padding: padding, child: child),
    ],
  );
}

class OrialisSectionHeader extends StatelessWidget {
  const OrialisSectionHeader({required this.title, super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(title, style: LuminaTheme.of(context).textTheme.titleMedium),
  );
}

class OrialisBottomActionBar extends StatelessWidget {
  const OrialisBottomActionBar({
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

class OrialisEmptyState extends StatelessWidget {
  const OrialisEmptyState({required this.text, this.card = true, super.key});
  final String text;
  final bool card;
  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: LuminaTheme.of(context).textTheme.bodyMedium.copyWith(
          color: LuminaTheme.of(context).colors.muted,
        ),
      ),
    );
    return card ? LuminaSurface(child: content) : Center(child: content);
  }
}

class OrialisChatBubble extends StatelessWidget {
  const OrialisChatBubble({
    required this.isUser,
    required this.child,
    super.key,
  });
  final bool isUser;
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(
    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.only(bottom: 12),
      child: LuminaSurface(
        color: isUser ? LuminaTheme.of(context).colors.accentSoft : null,
        radius: 22,
        child: child,
      ),
    ),
  );
}

class _GlassFilm extends CustomPainter {
  _GlassFilm(this.contact, this.phase, this.tint);
  final Offset contact;
  final double phase;
  final Color tint;
  @override
  void paint(Canvas canvas, Size size) {
    if (phase.abs() < .001) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)),
    );
    final center = Offset(contact.dx, contact.dy + phase * 3);
    final radius = (size.longestSide * .5 + 12) * (1 + (1 - phase) * .3);
    final p = Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius,
        [
          const Color(0x28FFFFFF).withValues(alpha: .12 * phase.clamp(0, 1)),
          tint.withValues(alpha: .025 * phase.clamp(0, 1)),
          const Color(0x00000000),
        ],
        [0, .55, 1],
      );
    canvas.drawRect(Offset.zero & size, p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassFilm old) =>
      phase != old.phase || contact != old.contact || tint != old.tint;
}
