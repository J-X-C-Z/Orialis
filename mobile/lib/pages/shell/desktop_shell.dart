import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../app/design/design_components.dart';

/// Desktop navigation reuses the same local-first product pages.
class DesktopShell extends StatefulWidget {
  const DesktopShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;
  static const labels = [
    '今日',
    '任务',
    '项目',
    '日历',
    '我的',
    'AI Hot',
    'GitHub',
    'Project',
    'Web 服务',
  ];
  static const icons = [
    LuminaIcons.today,
    LuminaIcons.tasks,
    LuminaIcons.folder,
    LuminaIcons.calendar,
    LuminaIcons.person,
    LuminaIcons.sparkles,
    LuminaIcons.branch,
    LuminaIcons.folder,
    LuminaIcons.devices,
  ];

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  ModalRoute<dynamic>? _route;
  static final _destinations = {
    LogicalKeyboardKey.digit1: 0,
    LogicalKeyboardKey.digit2: 1,
    LogicalKeyboardKey.digit3: 2,
    LogicalKeyboardKey.digit4: 3,
    LogicalKeyboardKey.digit5: 4,
    LogicalKeyboardKey.digit6: 5,
    LogicalKeyboardKey.digit7: 6,
    LogicalKeyboardKey.digit8: 7,
    LogicalKeyboardKey.digit9: 8,
  };

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed ||
        _route?.isCurrent != true) {
      return false;
    }
    final index = _destinations[event.logicalKey];
    if (index == null) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    widget.navigationShell.goBranch(index);
    return true;
  }

  Widget _destination(int index, {bool compact = false}) {
    final theme = LuminaTheme.of(context);
    final selected = widget.navigationShell.currentIndex == index;
    return Semantics(
      selected: selected,
      child: LuminaSurface(
        radius: 14,
        glass: selected,
        backdrop: selected,
        color: selected
            ? theme.colors.accentSoft.withValues(alpha: .65)
            : const Color(0x00000000),
        onTap: () => widget.navigationShell.goBranch(index),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: 12,
        ),
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaIcon(DesktopShell.icons[index], size: 20),
                  const SizedBox(height: 4),
                  Text(DesktopShell.labels[index]),
                ],
              )
            : Row(
                children: [
                  LuminaIcon(
                    DesktopShell.icons[index],
                    size: 20,
                    color: selected ? theme.colors.accent : theme.colors.muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      DesktopShell.labels[index],
                      style: theme.textTheme.bodyMedium.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  Text('⌘${index + 1}', style: theme.textTheme.bodySmall),
                ],
              ),
      ),
    );
  }

  Widget _sidebar() {
    final theme = LuminaTheme.of(context);
    return Container(
      key: const ValueKey('desktop-sidebar'),
      decoration: BoxDecoration(
        color: theme.colors.raisedSurface,
        border: Border(
          right: BorderSide(color: theme.colors.outline.withValues(alpha: .35)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                LuminaIcon(
                  LuminaIcons.home,
                  color: theme.colors.accent,
                  size: 23,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Orialis',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 38),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text('工作空间', style: theme.textTheme.bodySmall),
          ),
          for (var i = 0; i < 4; i++) ...[
            _destination(i),
            const SizedBox(height: 4),
          ],
          for (var i = 5; i < DesktopShell.labels.length; i++) ...[
            _destination(i),
            const SizedBox(height: 4),
          ],
          const Spacer(),
          Container(
            height: 1,
            color: theme.colors.outline.withValues(alpha: .35),
          ),
          const SizedBox(height: 12),
          _destination(4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return DesktopLayoutScope(
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: theme.colors.paper,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              const sidebarWidth = 224.0;
              final navigation = wide
                  ? _sidebar()
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: LuminaSurface(
                        glass: true,
                        radius: 20,
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: [
                            for (var i = 0; i < DesktopShell.labels.length; i++)
                              Expanded(child: _destination(i, compact: true)),
                          ],
                        ),
                      ),
                    );
              return LuminaNavigationInset(
                bottom: wide ? 0 : 100,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(left: wide ? sidebarWidth : 0),
                        child: widget.navigationShell,
                      ),
                    ),
                    // Keep navigation above branch Navigator semantics and hit testing.
                    if (wide)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        width: sidebarWidth,
                        child: navigation,
                      )
                    else
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: navigation,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
