import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart';

import 'mobile_navigation.dart';
import 'navigation_glass.dart';

/// Compact page modes share the navigation's frost, inset bed and flush lens.
class OrialisGlassSegmented<T> extends StatelessWidget {
  const OrialisGlassSegmented({
    required this.items,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final keys = items.keys.toList(growable: false);
    final selected = keys.indexOf(value).clamp(0, keys.length - 1);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (keys.length == 2 ? 252 : 264) * math.min(textScale, 1.4),
        ),
        child: OrialisNavigationGlassFrame(
          child: LuminaSurface(
            depth: LuminaSurfaceDepth.recessed,
            radius: LuminaControlSize.capsuleRadius,
            padding: const EdgeInsets.all(3),
            child: OrialisNavigationSelection(
              index: selected,
              enabled: List.filled(keys.length, true),
              glass: true,
              onSelectionChanged: (index) => onChanged(keys[index]),
              builder: (_) => Row(
                children: [
                  for (var i = 0; i < keys.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == selected,
                        child: LuminaSurface(
                          color: const Color(0x00000000),
                          radius: LuminaControlSize.capsuleRadius,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          onTap: () => onChanged(keys[i]),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Center(
                              child: Text(
                                items[keys[i]]!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium.copyWith(
                                  color: i == selected
                                      ? theme.colors.accent
                                      : theme.colors.muted,
                                  fontWeight: i == selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
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
          ),
        ),
      ),
    );
  }
}
