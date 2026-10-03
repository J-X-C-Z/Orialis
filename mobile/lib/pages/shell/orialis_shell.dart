import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart' show NavigationDestination;
import '../../app/design/design_components.dart';
import '../shared/mobile_navigation.dart';

class OrialisShell extends StatefulWidget {
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
  State<OrialisShell> createState() => _OrialisShellState();
}

class _OrialisShellState extends State<OrialisShell> {
  bool _conversationOpen = false;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<LuminaConversationVisibility>(
        onNotification: (notification) {
          if (_conversationOpen != notification.open) {
            setState(() => _conversationOpen = notification.open);
          }
          return true;
        },
        child: OrialisMobileNavigationOverlay(
          destinations: [
            for (var i = 0; i < OrialisShell._labels.length; i++)
              NavigationDestination(
                icon: LuminaIcon(
                  OrialisShell._icons[i],
                  color: LuminaTheme.of(context).colors.muted,
                ),
                selectedIcon: LuminaIcon(
                  OrialisShell._icons[i],
                  color: LuminaTheme.of(context).colors.accent,
                ),
                label: OrialisShell._labels[i],
              ),
          ],
          selectedIndex: widget.navigationShell.currentIndex,
          visible:
              !(widget.navigationShell.currentIndex == 2 && _conversationOpen),
          onDragEnd: (index) => widget.navigationShell.goBranch(index),
          onDestinationSelected: (index) => widget.navigationShell.goBranch(
            index,
            initialLocation: index == widget.navigationShell.currentIndex,
          ),
          child: widget.navigationShell,
        ),
      );
}
