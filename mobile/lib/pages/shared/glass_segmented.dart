import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart';

/// A real material host keeps the two pages' compact controls on one card.
class OrialisControlCard extends StatelessWidget {
  const OrialisControlCard({required this.child, super.key});
  final Widget child;

  static double extentOf(BuildContext context) {
    final fontSize =
        LuminaTheme.of(context).textTheme.labelMedium.fontSize ?? 14;
    return math
            .max(48.0, MediaQuery.textScalerOf(context).scale(fontSize) * 3 + 4)
            .ceilToDouble() +
        12;
  }

  @override
  Widget build(BuildContext context) => LuminaSurface(
    depth: LuminaSurfaceDepth.raised,
    liquidGlass: false,
    padding: const EdgeInsets.all(6),
    radius: 24,
    child: child,
  );
}

/// Page modes share the appearance selector material and retain compact labels.
class OrialisGlassSegmented<T> extends StatelessWidget {
  const OrialisGlassSegmented({
    required this.items,
    required this.value,
    required this.onChanged,
    this.compact = false,
    this.stretch = false,
    this.floating = false,
    this.direction = Axis.horizontal,
    super.key,
  });
  final Map<T, String> items;
  final T? value;
  final ValueChanged<T> onChanged;
  final bool compact;
  final bool stretch;
  final bool floating;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final keys = items.keys.toList(growable: false);
    final selected = value == null ? -1 : keys.indexOf(value as T);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final vertical = direction == Axis.vertical;
    final verticalSlotHeight = math.max(
      48.0,
      keys.map((key) => items[key]!.characters.length).fold(1, math.max) *
              MediaQuery.textScalerOf(context)
                  .scale(theme.textTheme.labelMedium.fontSize ?? 14) *
              1.4 +
          16,
    );
    final labels = Flex(
      direction: direction,
      mainAxisSize: vertical ? MainAxisSize.min : MainAxisSize.max,
      children: [
        for (var i = 0; i < keys.length; i++)
          Flexible(
            flex: 1,
            fit: vertical ? FlexFit.loose : FlexFit.tight,
            child: Semantics(
              selected: i == selected,
              child: LuminaSurface(
                color: const Color(0x00000000),
                radius: LuminaControlSize.capsuleRadius,
                padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 8),
                onTap: () => onChanged(keys[i]),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: vertical ? verticalSlotHeight : 44,
                  ),
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: LuminaTheme.motionReducedOf(context)
                          ? Duration.zero
                          : LuminaMotion.fast,
                      curve: luminaEaseOut,
                      style: theme.textTheme.labelMedium.copyWith(
                        color: i == selected
                            ? theme.colors.accent
                            : theme.colors.muted,
                        fontWeight: i == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      child: Text(
                        vertical
                            ? items[keys[i]]!.characters.join('\n')
                            : items[keys[i]]!,
                        semanticsLabel: items[keys[i]],
                        textAlign: TextAlign.center,
                        maxLines: vertical ? null : 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final track = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: vertical
            ? 56 * math.max(1, textScale)
            : (keys.length == 2 ? 252 : 264) * math.min(textScale, 1.4),
      ),
      child: LuminaSurface(
        key: const ValueKey('page-segment-track'),
        depth: LuminaSurfaceDepth.raised,
        glass: true,
        frosted: floating,
        backdrop: floating,
        diffuseGlass: true,
        radius: LuminaControlSize.capsuleRadius,
        padding: EdgeInsets.symmetric(
          horizontal: 4,
          vertical: compact && stretch ? 2 : 4,
        ),
        child: selected < 0
            ? labels
            : LuminaSlidingSelection(
                direction: direction,
                floating: floating,
                backdrop: !floating,
                index: selected,
                count: keys.length,
                onDragEnd: (index) => onChanged(keys[index]),
                child: labels,
              ),
      ),
    );
    return stretch ? track : Center(child: track);
  }
}
