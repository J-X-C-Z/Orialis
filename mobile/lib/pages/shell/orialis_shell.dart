import 'package:go_router/go_router.dart';
import '../../app/design/design_components.dart';

class OrialisShell extends StatelessWidget {
  const OrialisShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;
  static const _labels = ['今日', '事件', '聊天', '日历', '我的'];
  static const _icons = [
    LuminaIcons.today,
    LuminaIcons.tasks,
    LuminaIcons.chat,
    LuminaIcons.calendar,
    LuminaIcons.person,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return ColoredBox(
      color: theme.colors.paper,
      child: Column(
        children: [
          Expanded(child: navigationShell),
          if (MediaQuery.viewInsetsOf(context).bottom == 0)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: LuminaSurface(
                  glass: true,
                  radius: 28,
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      for (var i = 0; i < _labels.length; i++)
                        Expanded(
                          child: Semantics(
                            selected: navigationShell.currentIndex == i,
                            label: _labels[i],
                            child: LuminaSurface(
                              glass: navigationShell.currentIndex == i,
                              radius: 22,
                              color: navigationShell.currentIndex == i
                                  ? theme.colors.accentSoft
                                  : theme.colors.surface.withValues(alpha: 0),
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 2,
                              ),
                              onTap: () => navigationShell.goBranch(
                                i,
                                initialLocation:
                                    i == navigationShell.currentIndex,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  LuminaIcon(
                                    _icons[i],
                                    color: navigationShell.currentIndex == i
                                        ? theme.colors.accent
                                        : theme.colors.muted,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _labels[i],
                                    style: theme.textTheme.labelSmall,
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
        ],
      ),
    );
  }
}
