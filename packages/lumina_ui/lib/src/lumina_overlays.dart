part of 'design_components.dart';

Future<T?> showLuminaDialog<T>({
  required BuildContext context,
  WidgetBuilder? builder,
  String? title,
  Widget? content,
  List<Widget> actions = const [],
}) {
  final media = MediaQuery.of(context);
  final theme = LuminaTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: LuminaLocalizations.of(context).close,
    transitionBuilder: (c, a, b, child) =>
        luminaOverlayTransition(context, a, child),
    barrierColor: const Color(0x55131C24),
    transitionDuration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : LuminaMotion.standard,
    pageBuilder: (c, a, b) => MediaQuery(
      data: media,
      child: LuminaTheme(
        brightness: theme.brightness,
        reduceTransparency: theme.reduceTransparency,
        highPerformanceMode: theme.highPerformanceMode,
        tint: theme.tint,
        data: theme.data,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium,
          child: Center(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                24 + MediaQuery.viewInsetsOf(c).bottom,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 440,
                  maxHeight: 640,
                ),
                child: Builder(
                  builder: (overlayContext) =>
                      builder?.call(overlayContext) ??
                      LuminaDialog(
                        title: title ?? '',
                        content: content ?? const SizedBox(),
                        actions: actions,
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class LuminaDialog extends StatelessWidget {
  const LuminaDialog({
    required this.title,
    required this.content,
    this.actions = const [],
    super.key,
  });
  final String title;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LuminaSurface(
    liquidGlass: false,
    depth: LuminaSurfaceDepth.raised,
    padding: const EdgeInsets.all(24),
    radius: 28,
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            namesRoute: true,
            header: true,
            child: Text(
              title,
              style: LuminaTheme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 20),
          content,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: actions,
            ),
          ],
        ],
      ),
    ),
  );
}

Future<T?> showLuminaSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final media = MediaQuery.of(context);
  final theme = LuminaTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: LuminaLocalizations.of(context).closeSheet,
    transitionBuilder: (c, a, b, child) =>
        luminaOverlayTransition(c, a, child, sheet: true),
    barrierColor: const Color(0x55131C24),
    transitionDuration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : LuminaMotion.standard,
    pageBuilder: (c, a, b) => MediaQuery(
      data: media,
      child: LuminaTheme(
        brightness: theme.brightness,
        reduceTransparency: theme.reduceTransparency,
        highPerformanceMode: theme.highPerformanceMode,
        tint: theme.tint,
        data: theme.data,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedPadding(
              duration: media.disableAnimations
                  ? Duration.zero
                  : LuminaMotion.standard,
              curve: luminaEaseOut,
              padding: EdgeInsets.only(
                top: MediaQuery.viewPaddingOf(c).top + 12,
                bottom: MediaQuery.viewInsetsOf(c).bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 640,
                  maxHeight: MediaQuery.sizeOf(c).height * .85,
                ),
                child: LuminaSurface(
                  liquidGlass: false,
                  depth: LuminaSurfaceDepth.raised,
                  radius: 28,
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                  child: SafeArea(
                    top: false,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 18),
                            decoration: BoxDecoration(
                              color: LuminaTheme.of(context).colors.outline,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          Builder(
                            builder: (sheetContext) => MediaQuery.removePadding(
                              context: sheetContext,
                              removeTop: true,
                              removeBottom: true,
                              child: _LuminaSheetScope(
                                child: LuminaCardScope(
                                  child: Builder(builder: builder),
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
      ),
    ),
  );
}

OverlayEntry? _luminaMessageEntry;
_LuminaMessageState? _luminaMessageState;

/// Transient feedback above the floating navigation. A newer message replaces
/// the current one; an optional action (e.g. 撤销) keeps it tappable.
void showLuminaMessage(
  BuildContext context,
  String text, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final overlay = Overlay.of(context);
  final theme = LuminaTheme.of(context);
  final media = MediaQuery.of(context);
  // Sit above the floating tab bar instead of on top of it.
  final navigation = LuminaNavigationInset.of(context);
  _luminaMessageState?.dismiss(immediate: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (c) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(c).bottom + navigation + 16,
      child: MediaQuery(
        data: media,
        child: LuminaTheme(
          brightness: theme.brightness,
          reduceTransparency: theme.reduceTransparency,
          highPerformanceMode: theme.highPerformanceMode,
          tint: theme.tint,
          data: theme.data,
          child: _LuminaMessage(
            text: text,
            actionLabel: actionLabel,
            onAction: onAction,
            duration:
                duration ??
                (actionLabel == null
                    ? const Duration(seconds: 3)
                    : const Duration(seconds: 5)),
            onDone: () {
              if (identical(_luminaMessageEntry, entry)) {
                _luminaMessageEntry = null;
              }
              entry.remove();
              entry.dispose();
            },
          ),
        ),
      ),
    ),
  );
  _luminaMessageEntry = entry;
  overlay.insert(entry);
}

class _LuminaMessage extends StatefulWidget {
  const _LuminaMessage({
    required this.text,
    required this.duration,
    required this.onDone,
    this.actionLabel,
    this.onAction,
  });
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDone;
  @override
  State<_LuminaMessage> createState() => _LuminaMessageState();
}

class _LuminaMessageState extends State<_LuminaMessage>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: LuminaMotion.fast,
  );
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _luminaMessageState = this;
    _controller.forward();
    _timer = Timer(widget.duration, dismiss);
  }

  void dismiss({bool immediate = false}) {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (identical(_luminaMessageState, this)) _luminaMessageState = null;
    if (immediate || !mounted || LuminaTheme.motionReducedOf(context)) {
      widget.onDone();
      return;
    }
    _controller.reverse().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    if (identical(_luminaMessageState, this)) _luminaMessageState = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final reduced = LuminaTheme.motionReducedOf(context);
    final curved = CurvedAnimation(parent: _controller, curve: luminaEaseOut);
    final action = widget.actionLabel;
    Widget body = LuminaSurface(
      glass: true,
      padding: EdgeInsets.fromLTRB(16, 10, action == null ? 16 : 6, 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(widget.text)),
          if (action != null) ...[
            const SizedBox(width: 8),
            LuminaButton(
              primary: false,
              onPressed: () {
                widget.onAction?.call();
                dismiss();
              },
              child: Text(
                action,
                style: theme.textTheme.bodyMedium.copyWith(
                  color: theme.colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (action == null) body = IgnorePointer(child: body);
    return Center(
      child: Semantics(
        liveRegion: true,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium,
          child: FadeTransition(
            opacity: curved,
            child: reduced
                ? body
                : SlideTransition(
                    position: Tween(
                      begin: const Offset(0, .35),
                      end: Offset.zero,
                    ).animate(curved),
                    child: ScaleTransition(
                      scale: Tween(begin: .96, end: 1.0).animate(curved),
                      child: body,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

void showLuminaToast(
  BuildContext context,
  String text, {
  String? actionLabel,
  VoidCallback? onAction,
}) => showLuminaMessage(
  context,
  text,
  actionLabel: actionLabel,
  onAction: onAction,
);
Future<DateTime?> showLuminaDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  DateTime day(DateTime value) => DateTime(value.year, value.month, value.day);
  final first = day(firstDate),
      last = day(lastDate),
      initial = day(initialDate);
  assert(!last.isBefore(first), 'lastDate must not precede firstDate');
  assert(
    !initial.isBefore(first) && !initial.isAfter(last),
    'initialDate must be inside the allowed range',
  );
  return showLuminaDialog<DateTime>(
    context: context,
    builder: (c) =>
        _LuminaDatePickerBody(initial: initial, first: first, last: last),
  );
}

class _LuminaDatePickerBody extends StatefulWidget {
  const _LuminaDatePickerBody({
    required this.initial,
    required this.first,
    required this.last,
  });
  final DateTime initial, first, last;
  @override
  State<_LuminaDatePickerBody> createState() => _LuminaDatePickerBodyState();
}

class _LuminaDatePickerBodyState extends State<_LuminaDatePickerBody> {
  late DateTime date = widget.initial;
  late DateTime month = DateTime(date.year, date.month);
  double _direction = 0;
  bool _enabled(DateTime value) =>
      !value.isBefore(widget.first) && !value.isAfter(widget.last);
  void _select(DateTime next) {
    if (!_enabled(next)) return;
    setState(() {
      date = next;
      final nextMonth = DateTime(next.year, next.month);
      if (nextMonth != month) {
        _direction = nextMonth.compareTo(month).sign.toDouble();
      }
      month = nextMonth;
    });
  }

  DateTime _shiftMonth(int delta) {
    final target = DateTime(date.year, date.month + delta);
    return DateTime(
      target.year,
      target.month,
      math.min(date.day, DateTime(target.year, target.month + 1, 0).day),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LuminaLocalizations.of(context);
    final theme = LuminaTheme.of(context);
    final firstMonth = DateTime(widget.first.year, widget.first.month);
    final lastMonth = DateTime(widget.last.year, widget.last.month);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        final delta = key == LogicalKeyboardKey.arrowLeft
            ? (rtl ? 1 : -1)
            : key == LogicalKeyboardKey.arrowRight
            ? (rtl ? -1 : 1)
            : key == LogicalKeyboardKey.arrowUp
            ? -7
            : key == LogicalKeyboardKey.arrowDown
            ? 7
            : null;
        if (delta != null) {
          _select(DateTime(date.year, date.month, date.day + delta));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.pageUp ||
            key == LogicalKeyboardKey.pageDown) {
          _select(_shiftMonth(key == LogicalKeyboardKey.pageUp ? -1 : 1));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LuminaDialog(
        title: strings.selectDate,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                LuminaIconButton(
                  tooltip: strings.previousMonth,
                  onPressed: month.isAfter(firstMonth)
                      ? () => setState(() {
                          _direction = -1;
                          month = DateTime(month.year, month.month - 1);
                        })
                      : null,
                  icon: const LuminaIcon(LuminaIcons.arrowLeft),
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: LuminaSurface(
                      glass: true,
                      radius: LuminaControlSize.capsuleRadius,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 12,
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          '${month.year}/${month.month}',
                          style: theme.textTheme.labelMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
                LuminaIconButton(
                  tooltip: strings.nextMonth,
                  onPressed: month.isBefore(lastMonth)
                      ? () => setState(() {
                          _direction = 1;
                          month = DateTime(month.year, month.month + 1);
                        })
                      : null,
                  icon: const LuminaIcon(LuminaIcons.arrowRight),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: strings.weekdays
                  .map(
                    (day) => Expanded(
                      child: Text(
                        day,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall.copyWith(
                          color: theme.colors.muted,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              key: ValueKey('date-picker-month-${month.year}-${month.month}'),
              tween: Tween(begin: 0, end: 1),
              duration: LuminaTheme.motionReducedOf(context)
                  ? Duration.zero
                  : LuminaMotion.standard,
              curve: Curves.easeInOutCubic,
              builder: (context, progress, child) => Opacity(
                key: const ValueKey('date-picker-month'),
                opacity: .97 + .03 * progress,
                child: Transform.translate(
                  offset: Offset(
                    LuminaTheme.motionReducedOf(context)
                        ? 0
                        : _direction *
                              8 *
                              (1 - progress) *
                              theme.data.motionScale,
                    0,
                  ),
                  child: child,
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dayHeight = math.max(
                    44.0,
                    MediaQuery.textScalerOf(context).scale(15) * 1.5 + 12,
                  );
                  final cellWidth = math.max(
                    1.0,
                    (constraints.maxWidth - 12) / 7,
                  );
                  return GridView.count(
                    crossAxisCount: 7,
                    childAspectRatio: cellWidth / dayHeight,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 4,
                    children: List.generate(
                      DateTime(month.year, month.month + 1, 0).day +
                          month.weekday -
                          1,
                      (index) {
                        if (index < month.weekday - 1) return const SizedBox();
                        final day = DateTime(
                          month.year,
                          month.month,
                          index - month.weekday + 2,
                        );
                        final enabled = _enabled(day), selected = date == day;
                        final now = DateTime.now();
                        final today =
                            day.year == now.year &&
                            day.month == now.month &&
                            day.day == now.day;
                        return Semantics(
                          label:
                              '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
                          selected: selected,
                          enabled: enabled,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: selected ? 1 : 0),
                            duration: LuminaTheme.motionReducedOf(context)
                                ? Duration.zero
                                : LuminaMotion.fast,
                            curve: luminaEaseOut,
                            builder: (context, selection, _) => LuminaSurface(
                              key: ValueKey(
                                'date-picker-day-${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
                              ),
                              glass: true,
                              diffuseGlass: true,
                              radius: 12,
                              padding: const EdgeInsets.all(2),
                              color: Color.lerp(
                                Color.lerp(
                                  theme.colors.surface,
                                  theme.colors.accent,
                                  day.weekday > 5 ? .07 : 0,
                                ),
                                theme.colors.accentSoft,
                                selection,
                              ),
                              onTap: enabled ? () => _select(day) : null,
                              child: ExcludeSemantics(
                                child: Center(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '${day.day}',
                                      style: theme.textTheme.labelLarge
                                          .copyWith(
                                            fontWeight: FontWeight.lerp(
                                              today
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              FontWeight.w700,
                                              selection,
                                            ),
                                            color: !enabled
                                                ? theme.colors.muted
                                                : Color.lerp(
                                                    today || day.weekday > 5
                                                        ? theme.colors.accent
                                                        : theme.colors.ink,
                                                    theme.colors.accent,
                                                    selection,
                                                  ),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          LuminaButton(
            onPressed: () => Navigator.pop(context),
            primary: false,
            child: Text(strings.cancel),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(context, date),
            child: Text(strings.confirm),
          ),
        ],
      ),
    );
  }
}

Future<DateTime?> showLuminaTimePicker({
  required BuildContext context,
  required DateTime initialTime,
}) async {
  var hour = initialTime.hour, minute = initialTime.minute;
  return showLuminaDialog<DateTime>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => LuminaDialog(
        title: LuminaLocalizations.of(c).selectTime,
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final isHour in [true, false])
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LuminaIconButton(
                      tooltip: isHour
                          ? LuminaLocalizations.of(c).increaseHour
                          : LuminaLocalizations.of(c).increaseMinute,
                      onPressed: () => set(() {
                        if (isHour) {
                          hour = (hour + 1) % 24;
                        } else {
                          minute = (minute + 1) % 60;
                        }
                      }),
                      icon: const LuminaIcon(LuminaIcons.add),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        (isHour ? hour : minute).toString().padLeft(2, '0'),
                        style: LuminaTheme.of(c).textTheme.headlineMedium,
                      ),
                    ),
                    LuminaIconButton(
                      tooltip: isHour
                          ? LuminaLocalizations.of(c).decreaseHour
                          : LuminaLocalizations.of(c).decreaseMinute,
                      onPressed: () => set(() {
                        if (isHour) {
                          hour = (hour + 23) % 24;
                        } else {
                          minute = (minute + 59) % 60;
                        }
                      }),
                      icon: const LuminaIcon(LuminaIcons.chevronDown),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          LuminaButton(
            onPressed: () => Navigator.pop(c),
            primary: false,
            child: Text(LuminaLocalizations.of(c).cancel),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(
              c,
              DateTime(
                initialTime.year,
                initialTime.month,
                initialTime.day,
                hour,
                minute,
              ),
            ),
            child: Text(LuminaLocalizations.of(c).confirm),
          ),
        ],
      ),
    ),
  );
}
