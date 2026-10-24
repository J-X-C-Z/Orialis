import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'app_theme.dart';
import 'design_tokens.dart';
import 'lumina_motion.dart';

/// The standard Lumina reveal, with a sliver's lazy layout kept intact.
class LuminaSliverReveal extends StatelessWidget {
  const LuminaSliverReveal({
    required this.visible,
    required this.sliver,
    super.key,
  });

  final bool visible;
  final Widget sliver;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: visible ? 1 : 0),
    duration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : LuminaMotion.standard,
    curve: luminaEaseOut,
    child: SliverIgnorePointer(ignoring: !visible, sliver: sliver),
    builder: (context, value, child) => _SliverRevealExtent(
      progress: value,
      excludeSemantics: !visible,
      child: TickerMode(
        enabled: value > 0,
        child: SliverOpacity(opacity: value, sliver: child!),
      ),
    ),
  );
}

class _SliverRevealExtent extends SingleChildRenderObjectWidget {
  const _SliverRevealExtent({
    required this.progress,
    required this.excludeSemantics,
    required super.child,
  });
  final double progress;
  final bool excludeSemantics;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverRevealExtent(progress, excludeSemantics);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverRevealExtent renderObject,
  ) {
    renderObject.progress = progress;
    renderObject.excludeSemantics = excludeSemantics;
  }
}

class _RenderSliverRevealExtent extends RenderProxySliver {
  _RenderSliverRevealExtent(this._progress, this._excludeSemantics);
  double _progress;
  bool _excludeSemantics;
  set excludeSemantics(bool value) {
    if (_excludeSemantics == value) return;
    _excludeSemantics = value;
    markNeedsSemanticsUpdate();
  }

  set progress(double value) {
    if (_progress == value) return;
    _progress = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void performLayout() {
    if (_progress == 0 || child == null) {
      // Previously laid-out descendants must not keep dirty layout boundaries
      // behind a clean proxy when a folded card is rebuilt.
      if (child?.geometry != null) {
        child!.layout(
          constraints.copyWith(
            remainingPaintExtent: 0,
            remainingCacheExtent: 0,
            cacheOrigin: 0,
          ),
          parentUsesSize: true,
        );
      }
      geometry = SliverGeometry.zero;
      return;
    }
    child!.layout(constraints, parentUsesSize: true);
    final original = child!.geometry!;
    if (original.scrollOffsetCorrection != null || _progress == 1) {
      geometry = original;
      return;
    }
    final extent = original.scrollExtent * _progress;
    final paint = math.min(
      original.paintExtent,
      math.max(0.0, extent - constraints.scrollOffset),
    );
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintOrigin: original.paintOrigin,
      paintExtent: paint,
      layoutExtent: math.min(original.layoutExtent, paint),
      maxPaintExtent: original.maxPaintExtent * _progress,
      hitTestExtent: math.min(original.hitTestExtent, paint),
      cacheExtent: math.min(
        original.cacheExtent,
        math.max(
          0.0,
          extent - constraints.scrollOffset - constraints.cacheOrigin,
        ),
      ),
      hasVisualOverflow: original.hasVisualOverflow || _progress < 1,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || !geometry!.visible) return;
    if (_progress == 1) {
      super.paint(context, offset);
      return;
    }
    final direction = applyGrowthDirectionToAxisDirection(
      constraints.axisDirection,
      constraints.growthDirection,
    );
    final original = child!.geometry!;
    final extent = geometry!.paintExtent;
    final reverse =
        direction == AxisDirection.up || direction == AxisDirection.left;
    final start = reverse ? original.paintExtent - extent : 0.0;
    final clip = constraints.axis == Axis.vertical
        ? Rect.fromLTWH(0, start, constraints.crossAxisExtent, extent)
        : Rect.fromLTWH(start, 0, extent, constraints.crossAxisExtent);
    context.pushClipRect(needsCompositing, offset, clip, super.paint);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!_excludeSemantics && _progress > 0) {
      super.visitChildrenForSemantics(visitor);
    }
  }
}
