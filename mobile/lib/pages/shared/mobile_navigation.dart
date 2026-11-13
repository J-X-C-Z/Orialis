import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show NavigationDestination;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import 'navigation_glass.dart';
import 'adaptive_layout.dart';

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

  void _select(int index, {bool fromDrag = false}) {
    if (index < 0 ||
        index >= destinations.length ||
        !destinations[index].enabled) {
      return;
    }
    if (index != selectedIndex) unawaited(LuminaHaptics.selection());
    (fromDrag ? onDragEnd ?? onDestinationSelected : onDestinationSelected)(
      index,
    );
  }

  static double navigationInset(BuildContext context) {
    final label = LuminaTheme.of(context).textTheme.labelSmall;
    final theme = LuminaTheme.of(context);
    final layered = theme.data.neumorphic && theme.data.neumorphicGlass;
    return (layered ? 76 : 72) +
        MediaQuery.textScalerOf(context).scale(label.fontSize ?? 12) *
            (label.height ?? 1.2);
  }

  Widget _rail(BuildContext context, Widget bar, double width) {
    final theme = LuminaTheme.of(context);
    final label = theme.textTheme.labelSmall;
    final labelHeight =
        MediaQuery.textScalerOf(context).scale(label.fontSize!) *
        (label.height ?? 1.2);
    final slot = math.max(64.0, labelHeight + 42);
    return SafeArea(
      left: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: SingleChildScrollView(
          key: const ValueKey('adaptive-navigation-rail'),
          child: RotatedBox(
            quarterTurns: 1,
            child: SizedBox(
              width: destinations.length * slot + 24,
              height: width - 12,
              child: bar,
            ),
          ),
        ),
      ),
    );
  }

  Widget _navigationBar(BuildContext context, {bool vertical = false}) {
    final theme = LuminaTheme.of(context);
    final neumorphic = theme.data.neumorphic;
    final neumorphicGlass = neumorphic && theme.data.neumorphicGlass;
    Widget itemsAt(Animation<double> position) => Row(
      crossAxisAlignment: vertical
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < destinations.length; i++)
          Expanded(
            child: Semantics(
              selected: selectedIndex == i,
              enabled: destinations[i].enabled,
              label: destinations[i].label,
              child: LuminaSurface(
                radius: LuminaControlSize.capsuleRadius,
                color: const Color(0x00000000),
                padding: EdgeInsets.zero,
                onTap: destinations[i].enabled ? () => _select(i) : null,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (neumorphic && !neumorphicGlass)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            key: ValueKey('nav-recessed-selection-$i'),
                            opacity: selectedIndex == i ? 1 : 0,
                            duration: LuminaTheme.motionReducedOf(context)
                                ? Duration.zero
                                : LuminaMotion.fast,
                            curve: luminaEaseOut,
                            child: LuminaSurface(
                              depth: LuminaSurfaceDepth.recessed,
                              color: theme.colors.accentSoft,
                              radius: LuminaControlSize.capsuleRadius,
                              padding: EdgeInsets.zero,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(
                            vertical: 7,
                            horizontal: 2,
                          ) *
                          theme.data.spacingScale,
                      child: RotatedBox(
                        quarterTurns: vertical ? -1 : 0,
                        child: _EtchedNavigationLabel(
                          index: i,
                          position: position,
                          enabled: neumorphicGlass,
                          shaderRefraction: !vertical,
                          child: TweenAnimationBuilder<Color?>(
                            tween: ColorTween(
                              end: selectedIndex == i
                                  ? theme.colors.accent
                                  : theme.colors.muted,
                            ),
                            duration: LuminaTheme.motionReducedOf(context)
                                ? Duration.zero
                                : LuminaMotion.fast,
                            curve: luminaEaseOut,
                            builder: (context, color, _) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconTheme(
                                  data: IconThemeData(color: color),
                                  child: AnimatedSwitcher(
                                    duration:
                                        LuminaTheme.motionReducedOf(context)
                                        ? Duration.zero
                                        : LuminaMotion.fast,
                                    switchInCurve: luminaEaseOut,
                                    switchOutCurve: luminaEaseOut,
                                    child: KeyedSubtree(
                                      key: ValueKey(
                                        selectedIndex == i &&
                                            destinations[i].selectedIcon !=
                                                null,
                                      ),
                                      child: selectedIndex == i
                                          ? destinations[i].selectedIcon ??
                                                destinations[i].icon
                                          : destinations[i].icon,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  destinations[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall.copyWith(
                                    color: color,
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
                ),
              ),
            ),
          ),
      ],
    );
    final innerBar = LuminaSurface(
      depth: neumorphicGlass
          ? LuminaSurfaceDepth.recessed
          : LuminaSurfaceDepth.raised,
      glass: !neumorphic,
      backdrop: !neumorphic,
      radius: LuminaControlSize.capsuleRadius,
      padding: neumorphicGlass ? EdgeInsets.zero : const EdgeInsets.all(3),
      child: neumorphic
          ? OrialisNavigationSelection(
              index: selectedIndex,
              enabled: [
                for (final destination in destinations) destination.enabled,
              ],
              glass: neumorphicGlass,
              // Keep rotated glyphs out of image-filter sampling coordinates.
              shaderRefraction: !vertical,
              onSelectionChanged: (index) => _select(index, fromDrag: true),
              builder: itemsAt,
            )
          : LuminaSlidingSelection(
              index: selectedIndex,
              count: destinations.length,
              longTravel: true,
              backdrop: false,
              onDragEnd: (index) => _select(index, fromDrag: true),
              child: itemsAt(AlwaysStoppedAnimation(selectedIndex.toDouble())),
            ),
    );
    return RepaintBoundary(
      child: neumorphicGlass
          ? OrialisNavigationGlassFrame(child: innerBar)
          : innerBar,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final neumorphic = theme.data.neumorphic;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final showNavigation = visible && keyboardInset == 0;
    final navigationBar = _navigationBar(context);
    final labelWidth =
        MediaQuery.textScalerOf(context)
            .scale(theme.textTheme.labelSmall.fontSize ?? 13) *
        2;
    final railContentWidth = math.max(88.0, labelWidth + 40);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tablet =
            math.min(constraints.maxWidth, constraints.maxHeight) >= 600;
        final wide =
            constraints.maxWidth >= 600 &&
            (constraints.maxWidth > constraints.maxHeight || tablet);
        final railWidth = wide && showNavigation
            ? railContentWidth + MediaQuery.paddingOf(context).right
            : 0.0;
        return OrialisAdaptiveLayout(
          wide: wide,
          tablet: tablet,
          navigationWidth: railWidth,
          child: LuminaNavigationInset(
            bottom: showNavigation && !wide ? navigationInset(context) : 0,
            child: ColoredBox(
              color: theme.colors.paper,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: railWidth,
                        bottom: keyboardInset,
                      ),
                      child: MediaQuery(
                        data: MediaQuery.of(context)
                            .removeViewInsets(removeBottom: true)
                            .removePadding(removeRight: wide && showNavigation),
                        child: child,
                      ),
                    ),
                  ),
                  if (wide)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: keyboardInset,
                      width: railWidth,
                      child: showNavigation
                          ? _rail(
                              context,
                              _navigationBar(context, vertical: true),
                              railContentWidth,
                            )
                          : const SizedBox.shrink(),
                    )
                  else
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LuminaReveal(
                        visible: showNavigation,
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                            child: neumorphic
                                ? navigationBar
                                : ListenableBuilder(
                                    listenable: LuminaBlurPolicy
                                        .instance
                                        .chromeListenable,
                                    builder: (context, _) => navigationBar,
                                  ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class OrialisNavigationSelection extends StatefulWidget {
  const OrialisNavigationSelection({
    super.key,
    required this.index,
    required this.enabled,
    required this.glass,
    required this.onSelectionChanged,
    required this.builder,
    this.shaderRefraction = true,
  });

  final int index;
  final List<bool> enabled;
  final bool glass;
  final bool shaderRefraction;
  final ValueChanged<int> onSelectionChanged;
  final Widget Function(Animation<double> position) builder;

  @override
  State<OrialisNavigationSelection> createState() =>
      _OrialisNavigationSelectionState();
}

class _OrialisNavigationSelectionState extends State<OrialisNavigationSelection>
    with SingleTickerProviderStateMixin {
  late final LuminaSpring _position = LuminaSpring(
    vsync: this,
    value: widget.index.toDouble(),
  );
  bool _dragging = false;
  double _grabOffset = 0;

  int get _count => widget.enabled.length;

  double get _trackPadding =>
      widget.glass ? 3 * LuminaTheme.of(context).data.spacingScale : 0;

  double get _slotWidth =>
      ((context.size?.width ?? 0) - 2 * _trackPadding) / _count;

  int _logicalIndexAt(Offset position) {
    final width = _slotWidth;
    if (width <= 0) return widget.index;
    final physicalIndex = ((position.dx - _trackPadding) / width).floor().clamp(
      0,
      _count - 1,
    );
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
    unawaited(LuminaHaptics.dragStart());
    _position.stop();
    _grabOffset =
        details.localPosition.dx -
        _trackPadding -
        (_physicalPosition + .5) * width;
  }

  bool _enabled(int index) =>
      index >= 0 && index < _count && widget.enabled[index];

  void _moveDrag(Offset localPosition) {
    if (!_dragging) return;
    final width = _slotWidth;
    if (width <= 0) return;
    final last = (_count - 1).toDouble();
    final physical =
        ((localPosition.dx - _trackPadding - _grabOffset) / width - .5)
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
  void didUpdateWidget(OrialisNavigationSelection oldWidget) {
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
          shaderRefraction: widget.shaderRefraction,
          child: content!,
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

/// Tracks without shader sampling magnify the original labels directly.
class _EtchedNavigationLabel extends StatelessWidget {
  const _EtchedNavigationLabel({
    required this.index,
    required this.position,
    required this.enabled,
    required this.child,
    this.shaderRefraction = true,
  });
  final int index;
  final Animation<double> position;
  final bool enabled;
  final Widget child;
  final bool shaderRefraction;

  @override
  Widget build(BuildContext context) {
    final reduced = LuminaTheme.motionReducedOf(context);
    final active =
        enabled &&
        !reduced &&
        !LuminaTheme.of(context).reduceTransparency &&
        !MediaQuery.highContrastOf(context) &&
        (!shaderRefraction || !ui.ImageFilter.isShaderFilterSupported);
    return AnimatedBuilder(
      animation: position,
      child: child,
      builder: (context, label) {
        final distance = position.value - index;
        final weight = active ? math.max(0.0, 1 - distance.abs()) : 0.0;
        final depth = weight * weight * (3 - 2 * weight);
        final transform = Matrix4.identity()
          ..scaleByDouble(1 + depth * .035, 1 + depth * .035, 1, 1);
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
