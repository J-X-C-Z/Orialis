import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../app/design/design_components.dart';

class OrialisShell extends StatefulWidget {
  const OrialisShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;

  static const desktopBreakpoint = 960.0;
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

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
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
            if (constraints.maxWidth >= OrialisShell.desktopBreakpoint) {
              return _desktopShell(context);
            }
            return _mobileShell(context);
          },
        ),
      ),
    );
  }

  Widget _desktopShell(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return NotificationListener<LuminaConversationVisibility>(
      onNotification: (notification) {
        if (_conversationOpen != notification.open) {
          setState(() => _conversationOpen = notification.open);
        }
        return true;
      },
      child: LuminaNavigationInset(
        bottom: 0,
        child: ColoredBox(
          color: theme.colors.paper,
          child: Row(
            children: [
              SafeArea(
                right: false,
                minimum: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                child: SizedBox(
                  width: 232,
                  child: LuminaSurface(
                    depth: LuminaSurfaceDepth.raised,
                    radius: 28,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 18),
                          child: Row(
                            children: [
                              LuminaSurface(
                                color: theme.colors.accentSoft,
                                radius: 16,
                                padding: const EdgeInsets.all(9),
                                child: LuminaIcon(
                                  LuminaIcons.sparkles,
                                  color: theme.colors.accent,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Orialis',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (var i = 0; i < OrialisShell._labels.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _DesktopNavItem(
                              label: OrialisShell._labels[i],
                              icon: OrialisShell._icons[i],
                              shortcut: '⌘${i + 1}',
                              selected:
                                  widget.navigationShell.currentIndex == i,
                              onTap: () => _goBranch(i),
                            ),
                          ),
                        const Spacer(),
                        _DesktopNavItem(
                          label: '项目',
                          icon: LuminaIcons.folder,
                          selected: false,
                          onTap: () => context.go('/projects'),
                        ),
                        const SizedBox(height: 6),
                        _DesktopNavItem(
                          label: '设置',
                          icon: LuminaIcons.settings,
                          shortcut: '⌘,',
                          selected: false,
                          onTap: () => context.go('/profile'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(width: 1, color: theme.colors.outline),
              Expanded(child: widget.navigationShell),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileShell(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final showNavigation =
        MediaQuery.viewInsetsOf(context).bottom == 0 &&
        !(widget.navigationShell.currentIndex == 2 && _conversationOpen);
    final labelStyle = theme.textTheme.labelSmall;
    final bottom = showNavigation
        ? 72.0 +
              MediaQuery.textScalerOf(
                    context,
                  ).scale(labelStyle.fontSize ?? 12) *
                  (labelStyle.height ?? 1.2)
        : 0.0;
    return NotificationListener<LuminaConversationVisibility>(
      onNotification: (notification) {
        if (_conversationOpen != notification.open) {
          setState(() => _conversationOpen = notification.open);
        }
        return true;
      },
      child: LuminaNavigationInset(
        bottom: bottom,
        child: ColoredBox(
          color: theme.colors.paper,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: widget.navigationShell),
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
                          radius: AppControlSize.capsuleRadius,
                          padding: const EdgeInsets.all(6),
                          child: LuminaSlidingSelection(
                            index: widget.navigationShell.currentIndex,
                            count: OrialisShell._labels.length,
                            longTravel: true,
                            onDragEnd: _goBranch,
                            child: Row(
                              children: [
                                for (
                                  var i = 0;
                                  i < OrialisShell._labels.length;
                                  i++
                                )
                                  Expanded(
                                    child: Semantics(
                                      selected:
                                          widget.navigationShell.currentIndex ==
                                          i,
                                      label: OrialisShell._labels[i],
                                      child: LuminaSurface(
                                        radius: AppControlSize.capsuleRadius,
                                        color: const Color(0x00000000),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                          horizontal: 2,
                                        ),
                                        onTap: () => _goBranch(i),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            LuminaIcon(
                                              OrialisShell._icons[i],
                                              color:
                                                  widget
                                                          .navigationShell
                                                          .currentIndex ==
                                                      i
                                                  ? theme.colors.accent
                                                  : theme.colors.muted,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              OrialisShell._labels[i],
                                              style: theme.textTheme.labelSmall
                                                  .copyWith(
                                                    color:
                                                        widget
                                                                .navigationShell
                                                                .currentIndex ==
                                                            i
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
      ),
    );
  }
}

class _DesktopNavItem extends StatelessWidget {
  const _DesktopNavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.shortcut,
  });

  final String label;
  final LuminaIcons icon;
  final bool selected;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaSurface(
      color: selected ? theme.colors.accentSoft : const Color(0x00000000),
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      onTap: onTap,
      child: Row(
        children: [
          LuminaIcon(
            icon,
            color: selected ? theme.colors.accent : theme.colors.ink,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelMedium.copyWith(
                color: selected ? theme.colors.accent : theme.colors.ink,
              ),
            ),
          ),
          if (shortcut != null)
            Text(
              shortcut!,
              style: theme.textTheme.labelSmall.copyWith(
                color: theme.colors.muted,
              ),
            ),
        ],
      ),
    );
  }
}
