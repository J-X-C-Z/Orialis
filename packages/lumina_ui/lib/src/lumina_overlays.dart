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
    transitionBuilder: (c, a, b, child) => luminaOverlayTransition(c, a, child),
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

void showLuminaMessage(BuildContext context, String text) {
  final overlay = Overlay.of(context);
  final theme = LuminaTheme.of(context);
  final media = MediaQuery.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (c) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(c).bottom + 28,
      child: IgnorePointer(
        child: MediaQuery(
          data: media,
          child: LuminaTheme(
            brightness: theme.brightness,
            reduceTransparency: theme.reduceTransparency,
            highPerformanceMode: theme.highPerformanceMode,
            tint: theme.tint,
            data: theme.data,
            child: Center(
              child: Semantics(
                liveRegion: true,
                child: DefaultTextStyle(
                  style: theme.textTheme.bodyMedium,
                  child: LuminaSurface(glass: true, child: Text(text)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 3), () {
    entry.remove();
    entry.dispose();
  });
}

void showLuminaToast(BuildContext context, String text) =>
    showLuminaMessage(context, text);
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
  bool _enabled(DateTime value) =>
      !value.isBefore(widget.first) && !value.isAfter(widget.last);
  void _select(DateTime next) {
    if (!_enabled(next)) return;
    setState(() {
      date = next;
      month = DateTime(next.year, next.month);
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
                      ? () => setState(
                          () => month = DateTime(month.year, month.month - 1),
                        )
                      : null,
                  icon: const LuminaIcon(LuminaIcons.arrowLeft),
                ),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      '${month.year} / ${month.month}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                LuminaIconButton(
                  tooltip: strings.nextMonth,
                  onPressed: month.isBefore(lastMonth)
                      ? () => setState(
                          () => month = DateTime(month.year, month.month + 1),
                        )
                      : null,
                  icon: const LuminaIcon(LuminaIcons.arrowRight),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: strings.weekdays
                  .map(
                    (day) =>
                        Expanded(child: Text(day, textAlign: TextAlign.center)),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
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
                      return Semantics(
                        label:
                            '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
                        selected: selected,
                        enabled: enabled,
                        child: LuminaSurface(
                          glass: selected,
                          radius: 12,
                          padding: const EdgeInsets.all(2),
                          color: selected
                              ? theme.colors.accentSoft
                              : theme.colors.surface,
                          onTap: enabled ? () => _select(day) : null,
                          child: ExcludeSemantics(
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '${day.day}',
                                  style: theme.textTheme.bodyMedium.copyWith(
                                    color: enabled
                                        ? theme.colors.ink
                                        : theme.colors.muted,
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
