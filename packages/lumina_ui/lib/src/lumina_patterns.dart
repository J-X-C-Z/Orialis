part of 'design_components.dart';

/// Title-owned folding leaves actions independent and content state mounted.
class LuminaCollapsibleCard extends StatefulWidget {
  const LuminaCollapsibleCard({
    required this.storageId,
    required this.title,
    required this.child,
    this.trailing,
    this.summary,
    this.glassTitle,
    this.padding = LuminaCardMetrics.contentInsets,
    super.key,
  });
  final String storageId, title;
  final String? summary;
  final bool? glassTitle;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  @override
  State<LuminaCollapsibleCard> createState() => _LuminaCollapsibleCardState();
}

class _LuminaCollapsibleCardState extends State<LuminaCollapsibleCard> {
  late bool expanded = LuminaCardMemory.expanded(widget.storageId);
  @override
  Widget build(BuildContext context) => LuminaSurface(
    depth: LuminaSurfaceDepth.raised,
    shoulder: true,
    shoulderTitle: widget.title,
    shoulderTrailingSpace: widget.trailing == null ? 26 : 90,
    radius: 28,
    padding: widget.padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LuminaCardHeader(
          title: widget.title,
          trailing: widget.trailing,
          expanded: expanded,
          glassTitle: widget.glassTitle,
          onTitleTap: () {
            setState(() => expanded = !expanded);
            LuminaCardMemory.save(widget.storageId, expanded);
          },
        ),
        LuminaReveal(
          visible: expanded,
          child: Padding(
            padding: const EdgeInsets.only(
              top: LuminaCardMetrics.titleToContent,
            ),
            child: widget.child,
          ),
        ),
        LuminaReveal(
          visible: !expanded,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              widget.summary ?? LuminaLocalizations.of(context).collapsed,
              style: LuminaTheme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    ),
  );
}

class LuminaTint extends StatelessWidget {
  const LuminaTint({required this.color, required this.child, super.key});
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaTheme(
      brightness: theme.brightness,
      darkProgress: theme.colors.darkProgress,
      tint: color,
      highPerformanceMode: theme.highPerformanceMode,
      reduceTransparency: theme.reduceTransparency,
      data: theme.data,
      child: child,
    );
  }
}

/// Pages choose a named family rather than constructing per-card colors.
class LuminaPalette extends StatelessWidget {
  const LuminaPalette({required this.palette, required this.child, super.key});
  final LuminaCardPalette palette;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      LuminaTint(color: palette.tint, child: child);
}

class LuminaStack extends StatelessWidget {
  const LuminaStack({
    required this.children,
    this.gap = 12,
    this.mainAxisSize = MainAxisSize.min,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    super.key,
  });
  final List<Widget> children;
  final double gap;
  final MainAxisSize mainAxisSize;
  final CrossAxisAlignment crossAxisAlignment;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: mainAxisSize,
    crossAxisAlignment: crossAxisAlignment,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0 && children[i] is! SizedBox && children[i - 1] is! SizedBox)
          SizedBox(height: gap),
        children[i],
      ],
    ],
  );
}

class LuminaResize extends StatelessWidget {
  const LuminaResize({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => LuminaTheme.motionReducedOf(context)
      ? child
      : AnimatedSize(
          duration: LuminaMotion.standard,
          curve: luminaEaseOut,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          child: child,
        );
}

/// Reversible expansion keeps its contents mounted, preserving local state.
class LuminaReveal extends StatefulWidget {
  const LuminaReveal({required this.visible, required this.child, super.key});
  final bool visible;
  final Widget child;
  @override
  State<LuminaReveal> createState() => _LuminaRevealState();
}

class _LuminaRevealState extends State<LuminaReveal>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: LuminaMotion.standard,
    value: widget.visible ? 1 : 0,
  );
  bool reducedMotion = false;
  late bool contentActive = widget.visible;

  @override
  void initState() {
    super.initState();
    controller.addStatusListener(_handleStatus);
  }

  void _handleStatus(AnimationStatus _) {
    if (!controller.isAnimating &&
        controller.value == 0 &&
        !widget.visible &&
        contentActive) {
      setState(() => contentActive = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = LuminaTheme.motionReducedOf(context);
    if (reduced == reducedMotion) return;
    reducedMotion = reduced;
    if (reduced) {
      contentActive = widget.visible;
      controller.value = widget.visible ? 1 : 0;
    } else {
      _animateToTarget();
    }
  }

  @override
  void didUpdateWidget(LuminaReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      if (reducedMotion) {
        contentActive = widget.visible;
        controller.value = widget.visible ? 1 : 0;
      } else {
        if (widget.visible && !contentActive) {
          setState(() => contentActive = true);
        }
        _animateToTarget();
      }
    }
  }

  void _animateToTarget() {
    controller.animateTo(
      widget.visible ? 1 : 0,
      duration: LuminaMotion.standard,
      curve: luminaEaseOut,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: SizeTransition(
          sizeFactor: controller,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: controller,
            child: Offstage(
              offstage: !contentActive,
              child: TickerMode(enabled: contentActive, child: widget.child),
            ),
          ),
        ),
      ),
    ),
  );
}

class LuminaEngravedDivider extends StatelessWidget {
  const LuminaEngravedDivider({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SizedBox(
        height: 2,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.muted.withValues(alpha: .23), colors.surface],
            ),
          ),
        ),
      ),
    );
  }
}

class LuminaExpandableCard extends StatefulWidget {
  const LuminaExpandableCard({
    required this.expanded,
    required this.header,
    required this.summary,
    required this.detailBuilder,
    required this.onExpand,
    super.key,
  });
  final bool expanded;
  final Widget header, summary;
  final WidgetBuilder detailBuilder;
  final VoidCallback onExpand;
  @override
  State<LuminaExpandableCard> createState() => _LuminaExpandableCardState();
}

class _LuminaExpandableCardState extends State<LuminaExpandableCard> {
  late bool loaded = widget.expanded;
  @override
  void didUpdateWidget(LuminaExpandableCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    loaded = loaded || widget.expanded;
  }

  @override
  Widget build(BuildContext context) => LuminaSurface(
    depth: LuminaSurfaceDepth.raised,
    padding: LuminaCardMetrics.contentInsets,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.expanded ? null : widget.onExpand,
          child: widget.header,
        ),
        LuminaReveal(
          visible: !widget.expanded,
          child: Padding(
            padding: const EdgeInsets.only(
              top: LuminaCardMetrics.titleToContent,
            ),
            child: widget.summary,
          ),
        ),
        LuminaReveal(
          visible: widget.expanded,
          child: loaded
              ? Padding(
                  padding: const EdgeInsets.only(
                    top: LuminaCardMetrics.titleToContent,
                  ),
                  child: widget.detailBuilder(context),
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

class LuminaTap extends StatelessWidget {
  const LuminaTap({required this.child, this.onTap, this.behavior, super.key});
  final Widget child;
  final VoidCallback? onTap;
  final HitTestBehavior? behavior;
  @override
  Widget build(BuildContext context) => LuminaSurface(
    onTap: onTap,
    color: const Color(0x00000000),
    padding: EdgeInsets.zero,
    child: child,
  );
}

class _LuminaSheetScope extends InheritedWidget {
  const _LuminaSheetScope({required super.child});
  @override
  bool updateShouldNotify(_LuminaSheetScope oldWidget) => false;
}

/// Shared quoted-message preview for a composer or message bubble.
/// The application owns reply identity, persistence and source navigation.
class LuminaQuotePreview extends StatelessWidget {
  const LuminaQuotePreview({
    required this.title,
    required this.text,
    this.onTap,
    this.onDismiss,
    super.key,
  });
  final String title, text;
  final VoidCallback? onTap, onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaSurface(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colors.accentSoft,
      child: Row(
        children: [
          Container(width: 3, height: 36, color: theme.colors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              button: onTap != null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium.copyWith(
                          color: theme.colors.accent,
                        ),
                      ),
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (onDismiss != null)
            LuminaIconButton(
              icon: const LuminaIcon(LuminaIcons.close),
              onPressed: onDismiss,
              tooltip: LuminaLocalizations.of(context).cancelReply,
            ),
        ],
      ),
    );
  }
}
