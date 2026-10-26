import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
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

/// Keep branch state mounted, but lay out and paint only the active branch.
/// `Offstage` still lays out hidden navigators, which makes phone page switches
/// unnecessarily expensive when every branch contains a full-sized surface.
class LuminaBranchTransition extends StatefulWidget {
  const LuminaBranchTransition({
    required this.index,
    required this.children,
    this.animate = true,
    super.key,
  });
  final int index;
  final List<Widget> children;

  /// Disables the entrance without changing the retained branch widget tree.
  final bool animate;
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
    if (!widget.animate) {
      controller.stop();
      position = const AlwaysStoppedAnimation(Offset.zero);
      controller.value = 1;
      return;
    }
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
  Widget build(BuildContext context) {
    final branches = _LuminaActiveBranch(
      activeIndex: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          KeyedSubtree(
            key: ValueKey(i),
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
      ],
    );
    if (!widget.animate) return branches;
    return FadeTransition(
      opacity: LuminaTheme.motionReducedOf(context)
          ? Tween<double>(begin: .96, end: 1).animate(progress)
          : const AlwaysStoppedAnimation(1),
      child: SlideTransition(position: position, child: branches),
    );
  }
}

class _LuminaActiveBranch extends MultiChildRenderObjectWidget {
  const _LuminaActiveBranch({
    required this.activeIndex,
    required super.children,
  });

  final int activeIndex;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLuminaActiveBranch(activeIndex);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLuminaActiveBranch renderObject,
  ) {
    renderObject.activeIndex = activeIndex;
  }
}

class _LuminaBranchParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderLuminaActiveBranch extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _LuminaBranchParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _LuminaBranchParentData> {
  _RenderLuminaActiveBranch(this._activeIndex);

  int _activeIndex;

  int get activeIndex => _activeIndex;

  set activeIndex(int value) {
    if (_activeIndex == value) return;
    _activeIndex = value;
    markNeedsLayout();
  }

  RenderBox? get _activeChild {
    var index = 0;
    var child = firstChild;
    while (child != null && index < _activeIndex) {
      final parentData = child.parentData! as _LuminaBranchParentData;
      child = parentData.nextSibling;
      index++;
    }
    return child;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _LuminaBranchParentData) {
      child.parentData = _LuminaBranchParentData();
    }
  }

  @override
  void performLayout() {
    final child = _activeChild;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = _activeChild;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(constraints));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _activeChild?.paint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _activeChild?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(void Function(RenderObject child) visitor) {
    final child = _activeChild;
    if (child != null) visitor(child);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {}
}
