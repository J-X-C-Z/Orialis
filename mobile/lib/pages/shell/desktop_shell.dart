import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show DesktopLayoutScope;
import 'package:orialis_mobile/pages/shared/desktop_insights.dart';

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
    'Chat',
    '记忆',
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
    LuminaIcons.chat,
    LuminaIcons.folder,
  ];

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  ModalRoute<dynamic>? _route;
  bool _collapsed = false;
  bool _insightsVisible = true;
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
    LogicalKeyboardKey.digit0: 9,
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
    final macOS = defaultTargetPlatform == TargetPlatform.macOS;
    if (event is! KeyDownEvent ||
        (macOS
            ? !HardwareKeyboard.instance.isMetaPressed ||
                  HardwareKeyboard.instance.isControlPressed
            : !HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed) ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed ||
        _route?.isCurrent != true) {
      return false;
    }
    final index = _destinations[event.logicalKey];
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyB) {
      setState(() => _collapsed = !_collapsed);
      return true;
    }
    if (index == null) return false;
    widget.navigationShell.goBranch(index);
    return true;
  }

  Widget _destination(int index, {bool compact = false}) {
    final selected = widget.navigationShell.currentIndex == index;
    final palette = switch (index) {
      0 || 3 => LuminaCardPalette.ocean,
      1 => LuminaCardPalette.amber,
      2 || 7 || 9 => LuminaCardPalette.lavender,
      4 || 8 => LuminaCardPalette.mist,
      5 => LuminaCardPalette.rose,
      _ => LuminaCardPalette.sage,
    };
    final digit = index == 9 ? '0' : '${index + 1}';
    return LuminaPalette(
      palette: palette,
      child: Builder(
        builder: (context) {
          final theme = LuminaTheme.of(context);
          return Semantics(
            selected: selected,
            child: LuminaSurface(
              radius: 14,
              glass: selected,
              color: selected
                  ? theme.colors.accentSoft.withValues(alpha: .65)
                  : const Color(0x00000000),
              onTap: () => widget.navigationShell.goBranch(index),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 12,
                vertical: compact ? 8 : 10,
              ),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LuminaIcon(DesktopShell.icons[index], size: 20),
                        const SizedBox(height: 4),
                        Text(
                          DesktopShell.labels[index],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        LuminaIcon(
                          DesktopShell.icons[index],
                          size: 20,
                          color: selected
                              ? theme.colors.accent
                              : theme.colors.muted,
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
                        if (index < 10)
                          Text(
                            '${defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl+'}$digit',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _sidebar({required bool compact}) {
    final theme = LuminaTheme.of(context);
    Widget group(String title, List<int> indices) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
          child: Text(title, style: theme.textTheme.bodySmall,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        for (final index in indices)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _destination(index, compact: compact),
          ),
      ],
    );
    return Container(
      key: const ValueKey('desktop-sidebar'),
      decoration: BoxDecoration(
        color: theme.colors.raisedSurface,
        border: Border(right: BorderSide(
          color: theme.colors.outline.withValues(alpha: .35))),
      ),
      padding: EdgeInsets.fromLTRB(compact ? 6 : 14, 18, compact ? 6 : 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Image.asset('assets/branding/orialis-neumorphic-transparent.png',
                  width: 28, height: 28, excludeFromSemantics: true),
              if (!compact) ...[
                const SizedBox(width: 10),
                Expanded(child: Text('Orialis', style: theme.textTheme.titleMedium)),
              ],
            ]),
          ),
          Expanded(child: SingleChildScrollView(child: Column(children: [
            group('工作', [0, 1, 2, 3]),
            group('助手', [9, 10]),
            group('发现', [5, 6, 7, 8]),
          ]))),
          Container(height: 1, color: theme.colors.outline.withValues(alpha: .35)),
          const SizedBox(height: 8),
          _destination(4, compact: compact),
        ],
      ),
    );
  }

  Widget _toolbar({required bool canExpand, required bool canShowInsights}) {
    final theme = LuminaTheme.of(context);
    final modifier = defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl+';
    return Container(
      key: const ValueKey('desktop-workspace-toolbar'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(
        color: theme.colors.outline.withValues(alpha: .25)))),
      child: Row(children: [
        if (canExpand) ...[
          LuminaIconButton(
            key: const ValueKey('desktop-toggle-sidebar'),
            tooltip: '${_collapsed ? '展开' : '收起'}侧栏 · ${modifier}B',
            onPressed: () => setState(() => _collapsed = !_collapsed),
            icon: LuminaIcon(_collapsed ? LuminaIcons.arrowRight : LuminaIcons.arrowLeft),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(child: Text('${DesktopShell.labels[widget.navigationShell.currentIndex]} / 工作区',
            style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (canShowInsights)
          LuminaButton(
            key: const ValueKey('desktop-toggle-insights'),
            child: Text(_insightsVisible ? '收起概览' : '显示概览'),
            onPressed: () => setState(() => _insightsVisible = !_insightsVisible),
          ),
      ]),
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
              final wide = constraints.maxWidth >= 600;
              final compact = constraints.maxWidth < 1000 || _collapsed;
              final canShowInsights = constraints.maxWidth >= 1440 &&
                  widget.navigationShell.currentIndex != 9;
              final showInsights =
                  canShowInsights && _insightsVisible;
              final sidebarWidth = compact ? 88.0 : 224.0;
              const insightsWidth = 280.0;
              final navigation = wide
                  ? _sidebar(compact: compact)
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: LuminaSurface(
                        glass: true,
                        radius: 20,
                        padding: const EdgeInsets.all(6),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (
                                var i = 0;
                                i < DesktopShell.labels.length;
                                i++
                              )
                                SizedBox(
                                  width: 76,
                                  child: _destination(i, compact: true),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
              return LuminaNavigationInset(
                bottom: wide ? 0 : 100,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: wide ? sidebarWidth : 0,
                          right: showInsights ? insightsWidth : 0,
                        ),
                        child: Column(children: [
                          if (wide) _toolbar(
                            canExpand: constraints.maxWidth >= 1000,
                            canShowInsights: canShowInsights),
                          Expanded(child: widget.navigationShell),
                        ]),
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
                    if (showInsights)
                      const Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: insightsWidth,
                        child: DesktopInsightsPanel(),
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
