import 'package:flutter/material.dart' show NavigationDestination;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

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
    return 72 +
        MediaQuery.textScalerOf(context).scale(label.fontSize ?? 12) *
            (label.height ?? 1.2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final showNavigation = visible && keyboardInset == 0;
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
                    child: ListenableBuilder(
                      listenable: LuminaBlurPolicy.instance.chromeListenable,
                      builder: (context, _) => LuminaSurface(
                        depth: LuminaSurfaceDepth.raised,
                        glass: true,
                        backdrop: true,
                        radius: LuminaControlSize.capsuleRadius,
                        padding: const EdgeInsets.all(6),
                        child: LuminaSlidingSelection(
                          index: selectedIndex,
                          count: destinations.length,
                          longTravel: true,
                          backdrop: false,
                          onDragEnd: onDragEnd ?? onDestinationSelected,
                          child: Row(
                            children: [
                              for (var i = 0; i < destinations.length; i++)
                                Expanded(
                                  child: Semantics(
                                    selected: selectedIndex == i,
                                    label: destinations[i].label,
                                    child: LuminaSurface(
                                      radius: LuminaControlSize.capsuleRadius,
                                      color: const Color(0x00000000),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 2,
                                      ),
                                      onTap: destinations[i].enabled
                                          ? () => onDestinationSelected(i)
                                          : null,
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
                                                ? destinations[i]
                                                          .selectedIcon ??
                                                      destinations[i].icon
                                                : destinations[i].icon,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            destinations[i].label,
                                            style: theme.textTheme.labelSmall
                                                .copyWith(
                                                  color: selectedIndex == i
                                                      ? theme.colors.accent
                                                      : theme.colors.muted,
                                                ),
                                          ),
                                        ],
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
            ),
          ],
        ),
      ),
    );
  }
}
