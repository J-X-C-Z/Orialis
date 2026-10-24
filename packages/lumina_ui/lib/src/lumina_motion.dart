import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'app_theme.dart';

const luminaEaseOut = Cubic(.23, 1, .32, 1);
const luminaEaseDrawer = Cubic(.32, .72, 0, 1);

/// A small entrance on branch changes; the indexed branch stays mounted.
Widget luminaPageTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child,
) {
  if (LuminaTheme.motionReducedOf(context)) return child;
  final progress = animation.drive(CurveTween(curve: luminaEaseOut));
  return FadeTransition(
    opacity: Tween<double>(begin: .96, end: 1).animate(progress),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset(0, .006 * LuminaTheme.of(context).data.motionScale),
        end: Offset.zero,
      ).animate(progress),
      child: child,
    ),
  );
}

/// Route-owned animation reverses from its current position on dismissal.
Widget luminaOverlayTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  bool sheet = false,
}) {
  if (LuminaTheme.motionReducedOf(context)) return child;
  final progress = animation.drive(
    CurveTween(curve: sheet ? luminaEaseDrawer : luminaEaseOut),
  );
  return FadeTransition(
    opacity: progress,
    child: sheet
        ? SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(progress),
            child: child,
          )
        : ScaleTransition(
            scale: Tween<double>(begin: .96, end: 1).animate(progress),
            child: child,
          ),
  );
}

/// A spring keeps its current velocity when a gesture reverses direction.
class LuminaSpring extends AnimationController {
  LuminaSpring({required super.vsync, super.value}) : super.unbounded();

  /// A longer path needs more travel time so distant tabs do not dart across
  /// the entire bar. Retargeting still inherits the current position/velocity.
  void settleNavigation(double target, {bool reducedMotion = false}) {
    final distance = (target - value).abs();
    settle(
      target,
      reducedMotion: reducedMotion,
      description: distance >= 3
          ? const SpringDescription(mass: 1, stiffness: 165, damping: 25)
          : distance >= 1.6
          ? const SpringDescription(mass: 1, stiffness: 260, damping: 28)
          : const SpringDescription(mass: 1, stiffness: 380, damping: 29),
    );
  }

  void settle(
    double target, {
    bool reducedMotion = false,
    SpringDescription? description,
  }) {
    if (reducedMotion) {
      stop();
      value = target;
      return;
    }
    animateWith(
      SpringSimulation(
        description ??
            const SpringDescription(mass: 1, stiffness: 380, damping: 29),
        value,
        target,
        velocity,
        tolerance: const Tolerance(distance: .0005, velocity: .0005),
      ),
    );
  }
}

/// Keep branch state mounted, but paint only the destination during navigation.
/// A short paint-only entrance avoids blending two full-screen glass surfaces.
class LuminaBranchTransition extends StatefulWidget {
  const LuminaBranchTransition({
    required this.index,
    required this.children,
    super.key,
  });
  final int index;
  final List<Widget> children;
  @override
  State<LuminaBranchTransition> createState() => _LuminaBranchTransitionState();
}

class _LuminaBranchTransitionState extends State<LuminaBranchTransition>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final progress = controller.drive(CurveTween(curve: luminaEaseOut));
  Animation<Offset> position = const AlwaysStoppedAnimation(Offset.zero);

  @override
  void didUpdateWidget(LuminaBranchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    final reduced = LuminaTheme.motionReducedOf(context);
    final direction = widget.index > oldWidget.index ? 1.0 : -1.0;
    final start = controller.isAnimating
        ? position.value
        : Offset(direction * .025, 0);
    position = reduced
        ? const AlwaysStoppedAnimation(Offset.zero)
        : Tween<Offset>(begin: start, end: Offset.zero).animate(progress);
    controller.duration = Duration(milliseconds: reduced ? 140 : 220);
    controller.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LuminaTheme.motionReducedOf(context)) {
      position = const AlwaysStoppedAnimation(Offset.zero);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: LuminaTheme.motionReducedOf(context)
        ? Tween<double>(begin: .96, end: 1).animate(progress)
        : const AlwaysStoppedAnimation(1),
    child: SlideTransition(
      position: position,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            Positioned.fill(
              key: ValueKey(i),
              child: Offstage(
                offstage: i != widget.index,
                child: TickerMode(
                  enabled: i == widget.index,
                  child: IgnorePointer(
                    ignoring: i != widget.index,
                    child: ExcludeFocus(
                      excluding: i != widget.index,
                      child: ExcludeSemantics(
                        excluding: i != widget.index,
                        child: RepaintBoundary(child: widget.children[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
