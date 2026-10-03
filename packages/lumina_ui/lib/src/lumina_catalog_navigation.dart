part of 'lumina_catalog.dart';

/// Floating glass navigation. Destination data stays compatible with Flutter.
class LuminaNavigationBar extends StatelessWidget {
  const LuminaNavigationBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });
  final List<m.NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: LuminaSurface(
        glass: true,
        backdrop: true,
        diffuseGlass: true,
        depth: LuminaSurfaceDepth.raised,
        radius: LuminaControlSize.capsuleRadius,
        padding: const EdgeInsets.all(6),
        child: _LuminaNavGroup(
          selectedIndex: selectedIndex,
          onChanged: onDestinationSelected,
          entries: [
            for (var index = 0; index < destinations.length; index++)
              _LuminaNavEntry(
                key: destinations[index].key,
                icon: index == selectedIndex
                    ? destinations[index].selectedIcon ??
                          destinations[index].icon
                    : destinations[index].icon,
                label: Text(
                  destinations[index].label,
                  textAlign: TextAlign.center,
                ),
                enabled: destinations[index].enabled,
                tooltip:
                    destinations[index].tooltip ?? destinations[index].label,
              ),
          ],
        ),
      ),
    ),
  );
}

class LuminaBottomAppBar extends StatelessWidget {
  const LuminaBottomAppBar({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: LuminaSurface(
        glass: true,
        backdrop: true,
        diffuseGlass: true,
        depth: LuminaSurfaceDepth.raised,
        radius: LuminaControlSize.capsuleRadius,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: LuminaControlSize.minimum,
          ),
          child: child,
        ),
      ),
    ),
  );
}

/// A naturally sized row: multiline titles and accessibility scaling can grow.
class LuminaListTile extends StatelessWidget {
  const LuminaListTile({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    super.key,
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return Semantics(
      button: onTap != null,
      child: LuminaSurface(
        onTap: onTap,
        radius: LuminaRadius.control,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: LuminaControlSize.minimum,
          ),
          child: IconTheme(
            data: IconThemeData(color: theme.colors.muted, size: 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final text = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle(
                      style: theme.textTheme.bodyMedium,
                      child: title,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      DefaultTextStyle(
                        style: theme.textTheme.bodySmall,
                        child: subtitle!,
                      ),
                    ],
                  ],
                );
                // Tight columns place accessories above the text, avoiding a
                // competing three-column layout at large accessibility sizes.
                if (constraints.hasBoundedWidth && constraints.maxWidth < 180) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (leading != null || trailing != null) ...[
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [?leading, ?trailing],
                        ),
                        const SizedBox(height: 8),
                      ],
                      text,
                    ],
                  );
                }
                return Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: text),
                    if (trailing != null) ...[
                      const SizedBox(width: 12),
                      trailing!,
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class LuminaNavigationRail extends StatelessWidget {
  const LuminaNavigationRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.extended = false,
    super.key,
  });
  final List<m.NavigationRailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;
  final bool extended;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: extended ? 240 : 96,
    child: LuminaSurface(
      glass: true,
      depth: LuminaSurfaceDepth.raised,
      padding: const EdgeInsets.all(8),
      child: _LuminaNavGroup(
        axis: Axis.vertical,
        inline: extended,
        selectedIndex: selectedIndex,
        onChanged: onDestinationSelected,
        entries: [
          for (var index = 0; index < destinations.length; index++)
            _LuminaNavEntry(
              icon: index == selectedIndex
                  ? destinations[index].selectedIcon
                  : destinations[index].icon,
              label: destinations[index].label,
              enabled: !destinations[index].disabled,
            ),
        ],
      ),
    ),
  );
}

class LuminaNavigationDrawer extends StatelessWidget {
  const LuminaNavigationDrawer({
    required this.children,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });
  final List<Widget> children;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final destinations = children
        .whereType<m.NavigationDrawerDestination>()
        .toList();
    return SizedBox(
      width: 320,
      child: SafeArea(
        child: LuminaSurface(
          glass: true,
          depth: LuminaSurfaceDepth.raised,
          padding: const EdgeInsets.all(12),
          child: _LuminaNavGroup(
            axis: Axis.vertical,
            inline: true,
            selectedIndex: selectedIndex,
            onChanged: onDestinationSelected,
            entries: [
              for (var index = 0; index < destinations.length; index++)
                _LuminaNavEntry(
                  key: destinations[index].key,
                  icon: index == selectedIndex
                      ? destinations[index].selectedIcon ??
                            destinations[index].icon
                      : destinations[index].icon,
                  label: destinations[index].label,
                  enabled: destinations[index].enabled,
                ),
            ],
            childrenBuilder: (items) {
              var index = 0;
              return [
                for (final child in children)
                  if (child is m.NavigationDrawerDestination)
                    items[index++]
                  else
                    child,
              ];
            },
          ),
        ),
      ),
    );
  }
}

/// Card tabs share their selection with TabBarView and external controllers.
class LuminaTabs extends StatefulWidget {
  const LuminaTabs({required this.tabs, this.controller, super.key});
  final List<Widget> tabs;
  final m.TabController? controller;

  @override
  State<LuminaTabs> createState() => _LuminaNavTabsState();
}

class _LuminaNavTabsState extends State<LuminaTabs> {
  m.TabController? _controller;

  void _resolveController() {
    final next = widget.controller ?? m.DefaultTabController.maybeOf(context);
    if (next == _controller) return;
    _controller?.removeListener(_selectionChanged);
    _controller = next;
    _controller?.addListener(_selectionChanged);
  }

  void _selectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveController();
  }

  @override
  void didUpdateWidget(LuminaTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveController();
  }

  @override
  void dispose() {
    _controller?.removeListener(_selectionChanged);
    super.dispose();
  }

  // Material Tab reserves a fixed height. Extract its public content so text
  // scaling changes the natural height instead of overflowing that reservation.
  Widget _label(Widget tab) {
    if (tab is! m.Tab) return tab;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tab.icon != null) ...[
          tab.icon!,
          if (tab.text != null || tab.child != null)
            SizedBox(
              height:
                  tab.iconMargin?.resolve(Directionality.of(context)).bottom ??
                  8,
            ),
        ],
        if (tab.text != null) Text(tab.text!, textAlign: TextAlign.center),
        if (tab.child != null) tab.child!,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(
      _controller != null,
      'LuminaTabs requires a TabController or DefaultTabController.',
    );
    assert(
      _controller?.length == widget.tabs.length,
      'LuminaTabs and TabController lengths must match.',
    );
    return LuminaCardScope(
      child: LuminaSurface(
        glass: true,
        diffuseGlass: true,
        radius: LuminaControlSize.capsuleRadius,
        padding: const EdgeInsets.all(5),
        child: _LuminaNavGroup(
          selectedIndex: _controller?.index ?? 0,
          onChanged: _controller == null
              ? null
              : (index) => _controller!.animateTo(
                  index,
                  duration: LuminaTheme.motionReducedOf(context)
                      ? Duration.zero
                      : null,
                ),
          entries: [
            for (final tab in widget.tabs) _LuminaNavEntry(label: _label(tab)),
          ],
        ),
      ),
    );
  }
}

class _LuminaNavEntry {
  const _LuminaNavEntry({
    required this.label,
    this.icon,
    this.enabled = true,
    this.tooltip,
    this.key,
  });
  final Widget label;
  final Widget? icon;
  final bool enabled;
  final String? tooltip;
  final Key? key;
}

/// Arrow keys select and focus the next enabled destination; Tab retains the
/// host's normal traversal. Horizontal movement follows the reading direction.
class _LuminaNavGroup extends StatefulWidget {
  const _LuminaNavGroup({
    required this.entries,
    required this.selectedIndex,
    required this.onChanged,
    this.axis = Axis.horizontal,
    this.inline = false,
    this.childrenBuilder,
  });
  final List<_LuminaNavEntry> entries;
  final int selectedIndex;
  final ValueChanged<int>? onChanged;
  final Axis axis;
  final bool inline;
  final List<Widget> Function(List<Widget>)? childrenBuilder;

  @override
  State<_LuminaNavGroup> createState() => _LuminaNavGroupState();
}

class _LuminaNavGroupState extends State<_LuminaNavGroup> {
  final List<FocusNode> _nodes = [];
  final ScrollController _scrollController = ScrollController();

  void _resizeNodes() {
    while (_nodes.length < widget.entries.length) {
      _nodes.add(FocusNode());
    }
    while (_nodes.length > widget.entries.length) {
      _nodes.removeLast().dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    _resizeNodes();
    _revealSelected();
  }

  @override
  void didUpdateWidget(_LuminaNavGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resizeNodes();
    if (oldWidget.selectedIndex != widget.selectedIndex) _revealSelected();
  }

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal(widget.selectedIndex);
    });
  }

  void _reveal(int index) {
    if (!_scrollController.hasClients || index < 0 || index >= _nodes.length) {
      return;
    }
    final renderObject = _nodes[index].context?.findRenderObject();
    if (renderObject != null && renderObject.attached) {
      // Reveal inside this navigation viewport only. The host page keeps its
      // position even if an off-screen rail or tab selection changes.
      _scrollController.position.ensureVisible(renderObject, alignment: .5);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _key(int index, KeyEvent event) {
    if (event is! KeyDownEvent || widget.onChanged == null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    int? delta;
    if (widget.axis == Axis.horizontal) {
      final direction = Directionality.of(context) == TextDirection.rtl
          ? -1
          : 1;
      if (key == LogicalKeyboardKey.arrowRight) delta = direction;
      if (key == LogicalKeyboardKey.arrowLeft) delta = -direction;
    } else {
      if (key == LogicalKeyboardKey.arrowDown) delta = 1;
      if (key == LogicalKeyboardKey.arrowUp) delta = -1;
    }
    int? target;
    if (delta != null) {
      for (var step = 1; step <= widget.entries.length; step++) {
        final candidate = (index + step * delta) % widget.entries.length;
        if (widget.entries[candidate].enabled) {
          target = candidate;
          break;
        }
      }
    } else if (key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      final indices = key == LogicalKeyboardKey.home
          ? Iterable<int>.generate(widget.entries.length)
          : Iterable<int>.generate(widget.entries.length).toList().reversed;
      for (final candidate in indices) {
        if (widget.entries[candidate].enabled) {
          target = candidate;
          break;
        }
      }
    } else {
      return KeyEventResult.ignored;
    }
    if (target != null) {
      _nodes[target].requestFocus();
      widget.onChanged!(target);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      for (var index = 0; index < widget.entries.length; index++)
        _LuminaNavItem(
          key: widget.entries[index].key,
          entry: widget.entries[index],
          selected: index == widget.selectedIndex,
          inline: widget.inline,
          focusNode: _nodes[index],
          onFocus: () => _reveal(index),
          onKey: (event) => _key(index, event),
          onTap: widget.onChanged != null && widget.entries[index].enabled
              ? () => widget.onChanged!(index)
              : null,
        ),
    ];
    if (widget.axis == Axis.vertical) {
      final children = widget.childrenBuilder?.call(items) ?? items;
      return FocusTraversalGroup(
        child: SingleChildScrollView(
          controller: _scrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                children[index],
              ],
            ],
          ),
        ),
      );
    }
    return FocusTraversalGroup(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textSize = MediaQuery.textScalerOf(context).scale(14);
          final itemWidth = 72.0 + (textSize - 14).clamp(0, 100) * 2;
          final fits =
              constraints.hasBoundedWidth &&
              constraints.maxWidth >= items.length * itemWidth;
          final row = Row(
            mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
            children: [
              for (var index = 0; index < items.length; index++) ...[
                if (index > 0) const SizedBox(width: 6),
                if (fits)
                  Expanded(child: items[index])
                else
                  SizedBox(width: itemWidth, child: items[index]),
              ],
            ],
          );
          return fits
              ? row
              : SingleChildScrollView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  child: row,
                );
        },
      ),
    );
  }
}

class _LuminaNavItem extends StatefulWidget {
  const _LuminaNavItem({
    required this.entry,
    required this.selected,
    required this.inline,
    required this.focusNode,
    required this.onFocus,
    required this.onKey,
    required this.onTap,
    super.key,
  });
  final _LuminaNavEntry entry;
  final bool selected, inline;
  final FocusNode focusNode;
  final VoidCallback onFocus;
  final KeyEventResult Function(KeyEvent) onKey;
  final VoidCallback? onTap;

  @override
  State<_LuminaNavItem> createState() => _LuminaNavItemState();
}

class _LuminaNavItemState extends State<_LuminaNavItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final color = widget.selected ? theme.colors.ink : theme.colors.muted;
    final label = DefaultTextStyle(
      style: theme.textTheme.labelMedium.copyWith(color: color),
      child: widget.entry.label,
    );
    final icon = widget.entry.icon == null
        ? null
        : ExcludeSemantics(child: widget.entry.icon!);
    final inline =
        widget.inline && MediaQuery.textScalerOf(context).scale(14) < 35;
    Widget body = Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      enabled: widget.onTap != null,
      onTap: widget.onTap,
      child: Focus(
        focusNode: widget.focusNode,
        canRequestFocus: widget.onTap != null,
        onFocusChange: (value) {
          setState(() => _focused = value);
          if (value) {
            widget.onFocus();
          }
        },
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              widget.onTap != null &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            widget.onTap!();
            return KeyEventResult.handled;
          }
          return widget.onKey(event);
        },
        child: ExcludeFocus(
          child: Opacity(
            opacity: widget.onTap == null ? .45 : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  LuminaControlSize.capsuleRadius,
                ),
                border: Border.all(
                  color: _focused
                      ? theme.colors.accent
                      : const Color(0x00000000),
                  width: 2,
                ),
              ),
              child: LuminaSurface(
                glass: widget.selected,
                diffuseGlass: widget.selected,
                radius: LuminaControlSize.capsuleRadius,
                color: widget.selected
                    ? theme.colors.accentSoft
                    : const Color(0x00000000),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                onTap: widget.onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: LuminaControlSize.minimum,
                  ),
                  child: IconTheme(
                    data: IconThemeData(color: color, size: 24),
                    child: inline
                        ? Row(
                            children: [
                              if (icon != null) ...[
                                icon,
                                const SizedBox(width: 12),
                              ],
                              Expanded(child: label),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (icon != null) ...[
                                icon,
                                const SizedBox(height: 6),
                              ],
                              label,
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    body = MergeSemantics(child: body);
    if (widget.entry.tooltip != null && widget.entry.tooltip!.isNotEmpty) {
      body = LuminaTooltip(message: widget.entry.tooltip!, child: body);
    }
    return body;
  }
}
