import 'dart:math' as math;

import 'package:flutter/material.dart' show NavigationDestination;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import 'navigation_glass.dart';

/// Shared phone chrome for the schedule and news applications.
class OrialisMobileNavigationOverlay extends StatelessWidget {
  const OrialisMobileNavigationOverlay({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.child,
    this.onDragEnd,
    this.visible = true,
    super.key,
  });
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<int>? onDragEnd;
  final Widget child;
  final bool visible;

  static double navigationInset(BuildContext context) {
    final label = LuminaTheme.of(context).textTheme.labelSmall;
    final theme = LuminaTheme.of(context);
    final layered = theme.data.neumorphic && theme.data.neumorphicGlass;
    return (layered ? 84 : 72) +
        MediaQuery.textScalerOf(context).scale(label.fontSize ?? 12) *
            (label.height ?? 1.2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final neumorphic = theme.data.neumorphic;
    final neumorphicGlass = neumorphic && theme.data.neumorphicGlass;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final showNavigation = visible && keyboardInset == 0;
    Widget itemsAt(Animation<double> position) => Row(
      children: [
        for (var i = 0; i < destinations.length; i++)
          Expanded(
            child: Semantics(
              selected: selectedIndex == i,
              enabled: destinations[i].enabled,
              label: destinations[i].label,
              child: LuminaSurface(
                depth: neumorphic && !neumorphicGlass && selectedIndex == i
                    ? LuminaSurfaceDepth.recessed
                    : LuminaSurfaceDepth.normal,
                radius: LuminaControlSize.capsuleRadius,
                color: neumorphic && !neumorphicGlass && selectedIndex == i
                    ? null
                    : const Color(0x00000000),
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 2,
                ),
                onTap: destinations[i].enabled
                    ? () => onDestinationSelected(i)
                    : null,
                child: _EtchedNavigationLabel(
                  index: i,
                  position: position,
                  enabled: neumorphicGlass,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconTheme(
                        data: IconThemeData(
                          color: selectedIndex == i
                              ? theme.colors.accent
                              : theme.colors.muted,
                        ),
                        child: selectedIndex == i
                            ? destinations[i].selectedIcon ??
                                  destinations[i].icon
                            : destinations[i].icon,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        destinations[i].label,
                        style: theme.textTheme.labelSmall.copyWith(
                          color: selectedIndex == i
                              ? theme.colors.accent
                              : theme.colors.muted,
                          shadows:
                              neumorphicGlass &&
                                  !MediaQuery.highContrastOf(context)
                              ? [
                                  Shadow(
                                    color: theme.colors.tone(
                                      const Color(0xE6FFFFFF),
                                      const Color(0x88596775),
                                    ),
                                    offset: const Offset(.65, 1),
                                    blurRadius: .45,
                                  ),
                                  Shadow(
                                    color: theme.colors.tone(
                                      const Color(0x55536370),
                                      const Color(0xCC070D15),
                                    ),
                                    offset: const Offset(-.4, -.55),
                                    blurRadius: .35,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final innerBar = LuminaSurface(
      depth: LuminaSurfaceDepth.raised,
      glass: !neumorphic,
      backdrop: !neumorphic,
      radius: LuminaControlSize.capsuleRadius,
      padding: const EdgeInsets.all(6),
      child: neumorphic
          ? _NeumorphicNavigationSelection(
              index: selectedIndex,
              enabled: [
                for (final destination in destinations) destination.enabled,
              ],
              glass: neumorphicGlass,
              onSelectionChanged: onDragEnd ?? onDestinationSelected,
              builder: itemsAt,
            )
          : LuminaSlidingSelection(
              index: selectedIndex,
              count: destinations.length,
              longTravel: true,
              backdrop: false,
              onDragEnd: onDragEnd ?? onDestinationSelected,
              child: itemsAt(AlwaysStoppedAnimation(selectedIndex.toDouble())),
            ),
    );
    final navigationBar = RepaintBoundary(
      child: neumorphicGlass
          ? OrialisNavigationGlassFrame(child: innerBar)
          : innerBar,
    );
    return LuminaNavigationInset(
      bottom: showNavigation ? navigationInset(context) : 0,
      child: ColoredBox(
        color: theme.colors.paper,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(bottom: keyboardInset),
                child: MediaQuery.removeViewInsets(
                  context: context,
                  removeBottom: true,
                  child: child,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LuminaReveal(
                visible: showNavigation,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: neumorphic
                        ? navigationBar
                        : ListenableBuilder(
                            listenable:
                                LuminaBlurPolicy.instance.chromeListenable,
                            builder: (context, _) => navigationBar,
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
}

class _NeumorphicNavigationSelection extends StatefulWidget {
  const _NeumorphicNavigationSelection({
    required this.index,
    required this.enabled,
    required this.glass,
    required this.onSelectionChanged,
    required this.builder,
  });

  final int index;
  final List<bool> enabled;
  final bool glass;
  final ValueChanged<int> onSelectionChanged;
  final Widget Function(Animation<double> position) builder;

  @override
  State<_NeumorphicNavigationSelection> createState() =>
      _NeumorphicNavigationSelectionState();
}

class _NeumorphicNavigationSelectionState
    extends State<_NeumorphicNavigationSelection>
    with SingleTickerProviderStateMixin {
  late final LuminaSpring _position = LuminaSpring(
    vsync: this,
    value: widget.index.toDouble(),
  );
  bool _dragging = false;
  double _grabOffset = 0;

  int get _count => widget.enabled.length;

  double get _slotWidth => (context.size?.width ?? 0) / _count;

  int _logicalIndexAt(Offset position) {
    final width = _slotWidth;
    if (width <= 0) return widget.index;
    final physicalIndex = (position.dx / width).floor().clamp(0, _count - 1);
    return Directionality.of(context) == TextDirection.rtl
        ? _count - 1 - physicalIndex
        : physicalIndex;
  }

  double get _physicalPosition =>
      Directionality.of(context) == TextDirection.rtl
      ? _count - 1 - _position.value
      : _position.value;

  void _startDrag(LongPressStartDetails details) {
    if (_count == 0 || !_enabled(widget.index)) return;
    if (_logicalIndexAt(details.localPosition) != widget.index) return;
    final width = _slotWidth;
    if (width <= 0) return;
    _dragging = true;
    _position.stop();
    _grabOffset = details.localPosition.dx - (_physicalPosition + .5) * width;
  }

  bool _enabled(int index) =>
      index >= 0 && index < _count && widget.enabled[index];

  void _moveDrag(Offset localPosition) {
    if (!_dragging) return;
    final width = _slotWidth;
    if (width <= 0) return;
    final last = (_count - 1).toDouble();
    final physical = ((localPosition.dx - _grabOffset) / width - .5)
        .clamp(0.0, last)
        .toDouble();
    final logical = Directionality.of(context) == TextDirection.rtl
        ? (last - physical).round()
        : physical.round();
    if (!_enabled(logical)) return;
    _position.value = Directionality.of(context) == TextDirection.rtl
        ? last - physical
        : physical;
  }

  void _settleTo(int index) {
    _position.settleNavigation(
      index.toDouble(),
      reducedMotion: LuminaTheme.motionReducedOf(context),
    );
  }

  void _endDrag(LongPressEndDetails details) {
    if (!_dragging) return;
    _moveDrag(details.localPosition);
    _dragging = false;
    final releaseIndex = _logicalIndexAt(details.localPosition);
    if (!_enabled(releaseIndex)) {
      _settleTo(widget.index);
      return;
    }
    final target = _position.value.round().clamp(0, _count - 1);
    if (_enabled(target)) {
      _settleTo(target);
      if (target != widget.index) widget.onSelectionChanged(target);
    } else {
      _settleTo(widget.index);
    }
  }

  void _cancelDrag() {
    if (!_dragging) return;
    _dragging = false;
    _settleTo(widget.index);
  }

  @override
  void didUpdateWidget(_NeumorphicNavigationSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.enabled.length != _count) {
      _dragging = false;
      _settleTo(widget.index);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LuminaTheme.motionReducedOf(context)) {
      _position.settle(widget.index.toDouble(), reducedMotion: true);
    }
  }

  Widget _movingWell() => Positioned.fill(
    child: IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / _count;
          return Align(
            alignment: Alignment.centerLeft,
            child: Transform.translate(
              offset: Offset(
                _physicalPosition.clamp(0.0, _count - 1.0) * width,
                0,
              ),
              child: SizedBox(
                key: const ValueKey('nav-recess'),
                width: width,
                height: constraints.maxHeight,
                child: const LuminaSurface(
                  depth: LuminaSurfaceDepth.recessed,
                  radius: LuminaControlSize.capsuleRadius,
                  padding: EdgeInsets.zero,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onLongPressStart: _startDrag,
    onLongPressMoveUpdate: (details) => _moveDrag(details.localPosition),
    onLongPressEnd: _endDrag,
    onLongPressCancel: _cancelDrag,
    child: AnimatedBuilder(
      animation: _position,
      child: widget.builder(_position),
      builder: (context, content) {
        if (!widget.glass || _count == 0) return content!;
        return OrialisNavigationGlassLens(
          position: _position.value,
          count: _count,
          child: Stack(
            fit: StackFit.passthrough,
            children: [_movingWell(), content!],
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }
}

/// Engraving belongs to the soft bed; the glass only refracts its image.
class _EtchedNavigationLabel extends StatelessWidget {
  const _EtchedNavigationLabel({
    required this.index,
    required this.position,
    required this.enabled,
    required this.child,
  });
  final int index;
  final Animation<double> position;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = LuminaTheme.motionReducedOf(context);
    final active = enabled && !reduced && !MediaQuery.highContrastOf(context);
    return AnimatedBuilder(
      animation: position,
      child: child,
      builder: (context, label) {
        final distance = position.value - index;
        final weight = active ? math.max(0.0, 1 - distance.abs()) : 0.0;
        final depth = weight * weight * (3 - 2 * weight);
        final transform = Matrix4.identity()
          ..setEntry(0, 1, distance.clamp(-1.0, 1.0) * depth * .035)
          ..translateByDouble(0, depth * 1.8, 0, 1)
          ..scaleByDouble(1 - depth * .045, 1 - depth * .065, 1, 1);
        return Transform(
          key: ValueKey('nav-engraving-$index'),
          alignment: Alignment.center,
          transform: transform,
          transformHitTests: false,
          child: label,
        );
      },
    );
  }
}
