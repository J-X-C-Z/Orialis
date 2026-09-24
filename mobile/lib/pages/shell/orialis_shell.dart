import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';

class OrialisShell extends StatelessWidget {
  const OrialisShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  static const _destinations = <_ShellDestination>[
    _ShellDestination(
      label: '今日',
      icon: Icons.today_outlined,
      selectedIcon: Icons.today,
    ),
    _ShellDestination(
      label: '事件',
      icon: Icons.checklist_outlined,
      selectedIcon: Icons.checklist,
    ),
    _ShellDestination(
      label: '聊天',
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
    ),
    _ShellDestination(
      label: '日历',
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month,
    ),
    _ShellDestination(
      label: '我的',
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
    ),
  ];

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            _goBranch(0),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            _goBranch(1),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            _goBranch(2),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () =>
            _goBranch(3),
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true): () =>
            _goBranch(4),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            context.go('/profile'),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < AppBreakpoints.desktop) {
              return Scaffold(
                body: navigationShell,
                bottomNavigationBar: NavigationBar(
                  selectedIndex: navigationShell.currentIndex,
                  onDestinationSelected: _goBranch,
                  destinations: [
                    for (final item in _destinations)
                      NavigationDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: item.label,
                      ),
                  ],
                ),
              );
            }

            return Scaffold(
              backgroundColor: AppColors.paper,
              body: Row(
                children: [
                  const SizedBox(width: 12),
                  SafeArea(
                    minimum: const EdgeInsets.symmetric(vertical: 12),
                    child: SizedBox(
                      width: AppLayout.sidebarWidth,
                      child: _DesktopSidebar(
                        selectedIndex: navigationShell.currentIndex,
                        onSelected: _goBranch,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const VerticalDivider(width: 1),
                  Expanded(child: navigationShell),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return LuminaSolidSurface(
      color: AppColors.sidebar,
      radius: AppRadius.desktopPanel,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 6, 10, 18),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.accentSoft,
                  child: Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: AppColors.accent,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Orialis',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < OrialisShell._destinations.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _SidebarItem(
                destination: OrialisShell._destinations[index],
                selected: selectedIndex == index,
                shortcut: '⌘${index + 1}',
                onTap: () => onSelected(index),
              ),
            ),
          const Spacer(),
          const Divider(),
          _SidebarItem(
            destination: const _ShellDestination(
              label: '项目',
              icon: Icons.work_outline,
              selectedIcon: Icons.work,
            ),
            selected: false,
            onTap: () => context.push('/projects'),
          ),
          const SizedBox(height: 6),
          _SidebarItem(
            destination: const _ShellDestination(
              label: '设置',
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
            ),
            selected: false,
            shortcut: '⌘,',
            onTap: () => context.go('/profile'),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.shortcut,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    return LuminaGlassControl(
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 19,
                color: selected ? AppColors.accent : AppColors.ink,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  destination.label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (shortcut != null)
                Text(
                  shortcut!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellDestination {
  const _ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
