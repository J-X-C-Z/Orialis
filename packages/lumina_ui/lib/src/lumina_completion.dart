part of 'design_components.dart';

/// Native semantic feedback: never bypass the user's haptics preference.
class LuminaHaptics {
  /// Optional host-specific native feedback. Defaults to Flutter's platform API.
  static Future<void> Function()? confirmHandler;
  static Future<void> confirm() async {
    try {
      await (confirmHandler?.call() ?? HapticFeedback.lightImpact());
    } on MissingPluginException {
      await HapticFeedback.lightImpact();
    } on PlatformException {
      // Unsupported hardware must not fail a successful data operation.
    }
  }
}

class _CompletionScope extends InheritedWidget {
  const _CompletionScope({required this.run, required super.child});
  final Future<void> Function(FutureOr<void> Function(), BuildContext, bool)
  run;
  @override
  bool updateShouldNotify(_CompletionScope oldWidget) => false;
}

/// Retains completed rows until their recess closes. Opt-in keyed updates
/// animate list filtering without delaying the underlying data write.
class LuminaCompletionList extends StatefulWidget {
  const LuminaCompletionList({
    required this.children,
    this.gap = 12,
    this.empty = const SizedBox.shrink(),
    this.animateChanges = false,
    this.onCompletionActivityChanged,
    super.key,
  }) : itemKeys = null,
       itemBuilder = null;

  /// Builds rows lazily in a sliver. [itemKeys] must match the order and
  /// stable identity of the rows returned by [itemBuilder].
  const LuminaCompletionList.sliver({
    required this.itemKeys,
    required this.itemBuilder,
    this.gap = 12,
    this.empty = const SizedBox.shrink(),
    this.animateChanges = false,
    this.onCompletionActivityChanged,
    super.key,
  }) : children = const [];

  final List<Widget> children;
  final List<Key>? itemKeys;
  final IndexedWidgetBuilder? itemBuilder;
  final double gap;
  final Widget empty;

  /// Animate keyed additions/removals, such as changing an event filter.
  final bool animateChanges;
  final ValueChanged<bool>? onCompletionActivityChanged;
  @override
  State<LuminaCompletionList> createState() => _LuminaCompletionListState();
}

class _LuminaCompletionListState extends State<LuminaCompletionList> {
  late List<Widget> rows = List.of(widget.children);
  late List<Key> sliverRows = List.of(widget.itemKeys ?? const []);
  final Map<Key, Widget> mountedSliverChildren = {};
  final active = <Key>{};
  final departing = <Key>{};
  final arriving = <Key>{};
  @override
  void didUpdateWidget(LuminaCompletionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemKeys != null) {
      _updateSliverRows();
      return;
    }
    final next = List<Widget>.of(widget.children);
    final keys = next.map((w) => w.key).toSet();
    final previousKeys = rows.map((w) => w.key).toSet();
    if (widget.animateChanges) {
      for (final row in next) {
        if (!previousKeys.contains(row.key)) arriving.add(row.key!);
      }
    }
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (!keys.contains(row.key) &&
          (active.contains(row.key) || widget.animateChanges)) {
        departing.add(row.key!);
        next.insert(math.min(i, next.length), row);
      } else if (keys.contains(row.key)) {
        departing.remove(row.key);
      }
    }
    arriving.removeWhere((key) => !keys.contains(key));
    rows = next;
  }

  void _updateSliverRows() {
    final supplied = widget.itemKeys ?? const <Key>[];
    final next = List<Key>.of(supplied);
    final keys = supplied.toSet();
    final oldKeys = sliverRows.toSet();
    final oldIndexes = <int>{};
    for (var i = 0; i < sliverRows.length; i++) {
      if (mountedSliverChildren.containsKey(sliverRows[i])) oldIndexes.add(i);
    }
    if (widget.animateChanges) {
      if (sliverRows.isEmpty && supplied.isNotEmpty) {
        arriving.addAll(supplied.take(12));
      } else {
        for (final index in oldIndexes) {
          if (index < supplied.length && !oldKeys.contains(supplied[index])) {
            arriving.add(supplied[index]);
          }
        }
      }
    }
    for (var i = 0; i < sliverRows.length; i++) {
      final key = sliverRows[i];
      if (!keys.contains(key) &&
          (active.contains(key) ||
              (widget.animateChanges &&
                  mountedSliverChildren.containsKey(key)))) {
        departing.add(key);
        next.insert(math.min(i, next.length), key);
      } else if (keys.contains(key)) {
        departing.remove(key);
      }
    }
    arriving.removeWhere((key) => !keys.contains(key));
    sliverRows = next;
    final nextKeys = next.toSet();
    mountedSliverChildren.removeWhere((key, _) => !nextKeys.contains(key));
    if (arriving.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final unmounted = arriving
            .where((key) => !mountedSliverChildren.containsKey(key))
            .toSet();
        if (unmounted.isNotEmpty) {
          setState(() => arriving.removeAll(unmounted));
        }
      });
    }
  }

  void finishArrival(Key key) {
    if (!mounted || !arriving.contains(key)) return;
    setState(() => arriving.remove(key));
  }

  void finish(Key key) {
    if (!mounted) return;
    setState(() {
      active.remove(key);
      if (departing.remove(key)) {
        rows.removeWhere((w) => w.key == key);
        sliverRows.remove(key);
      }
      arriving.remove(key);
      mountedSliverChildren.remove(key);
    });
    widget.onCompletionActivityChanged?.call(active.isNotEmpty);
  }

  void start(Key key) {
    active.add(key);
    widget.onCompletionActivityChanged?.call(true);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemKeys != null) return _buildSliver(context);
    assert(rows.every((w) => w.key != null), 'Completion rows need stable IDs');
    final emptying =
        rows.isEmpty || rows.every((row) => departing.contains(row.key));
    // Keep the empty state's footprint throughout the last exit. The outer
    // card never contracts below its destination and then springs open again.
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        IgnorePointer(
          ignoring: !emptying,
          child: ExcludeSemantics(
            excluding: !emptying,
            child: AnimatedOpacity(
              opacity: emptying ? 1 : 0,
              duration: LuminaTheme.motionReducedOf(context)
                  ? Duration.zero
                  : LuminaMotion.standard,
              child: SizedBox(width: double.infinity, child: widget.empty),
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, row) in rows.indexed)
              _CompletionEntry(
                key: row.key,
                departing: departing.contains(row.key),
                arriving: arriving.contains(row.key),
                gap: i == rows.length - 1 ? 0 : widget.gap,
                onStart: () => start(row.key!),
                onEnd: () => finish(row.key!),
                onArrivalEnd: () => finishArrival(row.key!),
                child: row,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSliver(BuildContext context) {
    final currentKeys = widget.itemKeys!.toSet();
    final emptyKey = _SliverCompletionEmptyKey(this);
    final indexes = <Key, int>{
      emptyKey: 0,
      for (var i = 0; i < sliverRows.length; i++) sliverRows[i]: i + 1,
    };
    final currentIndexes = <Key, int>{
      for (var i = 0; i < widget.itemKeys!.length; i++) widget.itemKeys![i]: i,
    };
    final emptying =
        sliverRows.isEmpty ||
        sliverRows.every((key) => departing.contains(key));
    return SliverList.builder(
      itemCount: sliverRows.length + 1,
      findChildIndexCallback: (key) => indexes[key],
      itemBuilder: (context, index) {
        if (index == 0) {
          return KeyedSubtree(
            key: emptyKey,
            child: _SliverCompletionEmpty(
              visible: sliverRows.isEmpty,
              child: widget.empty,
            ),
          );
        }
        final rowIndex = index - 1;
        final key = sliverRows[rowIndex];
        final departingRow = departing.contains(key);
        final child = currentKeys.contains(key)
            ? widget.itemBuilder!(context, currentIndexes[key]!)
            : mountedSliverChildren[key] ?? const SizedBox.shrink();
        final entry = _CompletionEntry(
          departing: departingRow,
          arriving: arriving.contains(key),
          preserveExtentDuringArrival: true,
          gap: rowIndex == sliverRows.length - 1 ? 0 : widget.gap,
          onStart: () => start(key),
          onEnd: () => finish(key),
          onArrivalEnd: () => finishArrival(key),
          onMount: () => mountedSliverChildren[key] = child,
          onDispose: () => mountedSliverChildren.remove(key),
          child: child,
        );
        final lastAndEmptying = rowIndex == sliverRows.length - 1 && emptying;
        return KeyedSubtree(
          key: key,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              entry,
              if (lastAndEmptying)
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: double.infinity,
                      child: widget.empty,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SliverCompletionEmptyKey extends ValueKey<Object> {
  const _SliverCompletionEmptyKey(super.value);
}

class _SliverCompletionEmpty extends StatefulWidget {
  const _SliverCompletionEmpty({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  State<_SliverCompletionEmpty> createState() => _SliverCompletionEmptyState();
}

class _SliverCompletionEmptyState extends State<_SliverCompletionEmpty>
    with SingleTickerProviderStateMixin {
  late final AnimationController _extent = AnimationController(
    vsync: this,
    duration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : LuminaMotion.standard,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(_SliverCompletionEmpty oldWidget) {
    super.didUpdateWidget(oldWidget);
    _extent.duration = LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : LuminaMotion.standard;
    if (widget.visible && !oldWidget.visible) {
      // The exiting row already holds this exact footprint until it is removed.
      _extent.value = 1;
    } else if (!widget.visible && oldWidget.visible) {
      _extent.reverse();
    }
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    alignment: Alignment.topCenter,
    sizeFactor: _extent,
    child: FadeTransition(
      opacity: _extent,
      child: SizedBox(width: double.infinity, child: widget.child),
    ),
  );
}

class _CompletionEntry extends StatefulWidget {
  const _CompletionEntry({
    required this.departing,
    required this.arriving,
    required this.gap,
    this.preserveExtentDuringArrival = false,
    required this.onStart,
    required this.onEnd,
    required this.onArrivalEnd,
    this.onMount,
    this.onDispose,
    required this.child,
    super.key,
  });
  final bool departing;
  final bool arriving;
  final double gap;
  final bool preserveExtentDuringArrival;
  final VoidCallback onStart, onEnd;
  final VoidCallback onArrivalEnd;
  final VoidCallback? onMount, onDispose;
  final Widget child;
  @override
  State<_CompletionEntry> createState() => _CompletionEntryState();
}

class _CompletionEntryState extends State<_CompletionEntry>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: LuminaMotion.fluid,
  );
  late final arrival = AnimationController(
    vsync: this,
    duration: LuminaMotion.standard,
    value: widget.arriving ? 0 : 1,
  );
  bool busy = false;
  bool exiting = false;
  bool undoing = false;
  Offset? origin;
  @override
  bool get wantKeepAlive => busy || widget.departing;
  @override
  void initState() {
    super.initState();
    widget.onMount?.call();
    if (widget.arriving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enter();
      });
    }
  }

  Future<void> _enter() async {
    try {
      arrival.duration = LuminaTheme.motionReducedOf(context)
          ? Duration.zero
          : LuminaMotion.standard;
      await arrival.forward().orCancel;
      if (mounted) widget.onArrivalEnd();
    } on TickerCanceled {
      // An interrupted filter change can remove the row mid-entry.
    }
  }

  @override
  void didUpdateWidget(_CompletionEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.onMount?.call();
    if (widget.departing != oldWidget.departing) updateKeepAlive();
    if (widget.departing && !oldWidget.departing && !busy) {
      exiting = true;
      _exit();
    } else if (!widget.departing && oldWidget.departing && exiting) {
      _restore();
    }
  }

  Future<void> _exit() async {
    try {
      controller.duration = LuminaTheme.motionReducedOf(context)
          ? Duration.zero
          : LuminaMotion.standard;
      await controller.forward().orCancel;
      if (mounted && widget.departing) widget.onEnd();
    } on TickerCanceled {
      // A rapid filter reversal retargets the current frame.
    }
  }

  Future<void> _restore() async {
    try {
      controller.reverseDuration = LuminaTheme.motionReducedOf(context)
          ? Duration.zero
          : LuminaMotion.standard;
      await controller.reverse().orCancel;
      if (mounted && !widget.departing) setState(() => exiting = false);
    } on TickerCanceled {
      // The row may be leaving again.
    }
  }

  Future<void> run(
    FutureOr<void> Function() action,
    BuildContext trigger,
    bool becomingComplete,
  ) async {
    if (busy) return;
    busy = true;
    updateKeepAlive();
    undoing = !becomingComplete;
    final box = context.findRenderObject() as RenderBox?;
    final button = trigger.findRenderObject() as RenderBox?;
    if (box != null && button != null) {
      origin = box.globalToLocal(
        button.localToGlobal(button.size.center(Offset.zero)),
      );
    }
    widget.onStart();
    try {
      await action(); // Never wait for the animation before saving.
      if (!mounted) return;
      unawaited(LuminaHaptics.confirm());
      controller.duration = LuminaTheme.motionReducedOf(context)
          ? LuminaMotion.fast
          : LuminaMotion.fluid;
      await controller.forward(from: 0).orCancel;
      if (!mounted) return;
      busy = false;
      updateKeepAlive();
      widget.onEnd();
      if (mounted) controller.value = 0;
    } on TickerCanceled {
      // Navigating away does not cancel the already-started save.
    } catch (_) {
      busy = false;
      updateKeepAlive();
      if (!mounted) return;
      widget.onEnd();
      showLuminaDialog<void>(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(LuminaLocalizations.of(context).saveFailed),
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.onDispose?.call();
    controller.dispose();
    arrival.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reduced = LuminaTheme.motionReducedOf(context);
    final colors = LuminaTheme.of(context).colors;
    return _CompletionScope(
      run: run,
      child: AnimatedBuilder(
        animation: Listenable.merge([controller, arrival]),
        child: RepaintBoundary(child: widget.child),
        builder: (context, child) {
          final t = controller.value;
          // One small elastic recoil before the upper and lower lips meet.
          final close = luminaEaseOut.transform(
            ((t - .18) / .82).clamp(0.0, 1.0),
          );
          // Undo briefly opens the recess before the row is released.
          final flare = undoing && !reduced
              ? math.sin((t / .36).clamp(0.0, 1.0) * math.pi) * .075
              : 0.0;
          final releaseClose = undoing
              ? luminaEaseOut.transform(((t - .28) / .72).clamp(0.0, 1.0))
              : close;
          final recoil = math.sin(t * math.pi * 3) * math.exp(-t * 7) * .055;
          // Completed rows that stay in a project close and reopen in place.
          // Rows leaving a filtered list close fully before removal.
          final closing = widget.departing || exiting;
          final aperture = reduced
              ? 0.0
              : closing
              ? releaseClose
              : math.sin(t * math.pi) * .34;
          final collapse = (1 + flare - aperture) * arrival.value;
          return SizedBox(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor:
                  widget.preserveExtentDuringArrival && widget.arriving
                  ? 1
                  : collapse,
              child: Padding(
                padding: EdgeInsets.only(bottom: widget.gap),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IgnorePointer(
                      ignoring: busy || widget.departing,
                      child: Opacity(
                        opacity: closing
                            ? 1 - releaseClose
                            : (1 - aperture * .15) * arrival.value,
                        child: ClipPath(
                          clipBehavior: Clip.antiAlias,
                          clipper: _CompletionAperture(
                            1 - collapse.clamp(0.0, 1.0),
                          ),
                          child: CustomPaint(
                            foregroundPainter: _CompletionRim(
                              (1 - collapse).clamp(0.0, 1.0),
                              colors,
                            ),
                            child: Transform.scale(
                              alignment: Alignment.topCenter,
                              scaleX: reduced
                                  ? 1
                                  : 1 +
                                        (undoing ? -recoil : recoil) +
                                        flare -
                                        aperture * .06,
                              scaleY: reduced ? 1 : 1 - recoil + flare * .5,
                              child: aperture > 0
                                  ? FractionalTranslation(
                                      translation: Offset(0, -aperture * .5),
                                      child: child,
                                    )
                                  : child,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (t > 0 && !reduced)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _CompletionBurst(
                              t,
                              origin,
                              colors,
                              closing,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Opposing rounded lips meet rather than flattening glyphs into a line.
class _CompletionAperture extends CustomClipper<Path> {
  const _CompletionAperture(this.close);
  final double close;
  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height * (1 - close)),
        const Radius.circular(24),
      ),
    );
  @override
  bool shouldReclip(_CompletionAperture old) => old.close != close;
}

/// Rebuild the rim at the moving opening instead of exposing a cut edge.
class _CompletionRim extends CustomPainter {
  const _CompletionRim(this.close, this.colors);
  final double close;
  final LuminaColors colors;
  @override
  void paint(Canvas canvas, Size size) {
    if (close <= 0 || close >= 1) return;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height * (1 - close));
    if (rect.height <= 1.2 || rect.width <= 1.2) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(.6), const Radius.circular(24)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          colors.muted.withValues(alpha: .22 * math.sin(close * math.pi)),
          colors.surface.withValues(alpha: .8 * math.sin(close * math.pi)),
        ]),
    );
  }

  @override
  bool shouldRepaint(_CompletionRim old) =>
      old.close != close || old.colors != colors;
}

class _CompletionBurst extends CustomPainter {
  _CompletionBurst(this.progress, this.origin, this.colors, this.closing);
  final double progress;
  final Offset? origin;
  final LuminaColors colors;
  final bool closing;
  @override
  void paint(Canvas canvas, Size size) {
    final p = luminaEaseOut.transform(progress);
    final center = origin ?? Offset(size.width - 36, 36);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colors.accent.withValues(alpha: (1 - progress) * .65);
    // The lens opens into a broken ring and six short-lived glass droplets.
    for (var i = 0; i < 6; i++) {
      final angle = i * math.pi / 3;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: 22 + p * 15),
        angle + p * .25,
        .62 * (1 - p),
        false,
        paint,
      );
      final offset = Offset(math.cos(angle), math.sin(angle)) * (24 + p * 24);
      canvas.drawCircle(
        center + offset,
        3 * (1 - p) + .4,
        Paint()..color = colors.accentSoft.withValues(alpha: 1 - progress),
      );
    }
  }

  @override
  bool shouldRepaint(_CompletionBurst old) =>
      old.progress != progress ||
      old.origin != origin ||
      old.closing != closing ||
      old.colors != colors;
}
