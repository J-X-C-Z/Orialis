part of 'design_components.dart';

Future<T?> showLuminaDialog<T>({
  required BuildContext context,
  WidgetBuilder? builder,
  String? title,
  Widget? content,
  List<Widget> actions = const [],
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭',
  barrierColor: const Color(0x55131C24),
  transitionDuration: MediaQuery.maybeOf(context)?.disableAnimations == true
      ? Duration.zero
      : LuminaMotion.standard,
  pageBuilder: (c, a, b) => LuminaTheme(
    brightness: LuminaTheme.of(context).brightness,
    reduceTransparency: LuminaTheme.of(context).reduceTransparency,
    child: DefaultTextStyle(
      style: LuminaTheme.of(context).textTheme.bodyMedium,
      child: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(c).bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
            child:
                builder?.call(c) ??
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
);

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
    glass: true,
    padding: const EdgeInsets.all(24),
    radius: 28,
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: LuminaTheme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          content,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 10,
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
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭面板',
  barrierColor: const Color(0x55131C24),
  transitionDuration: MediaQuery.maybeOf(context)?.disableAnimations == true
      ? Duration.zero
      : LuminaMotion.standard,
  pageBuilder: (c, a, b) => LuminaTheme(
    brightness: LuminaTheme.of(context).brightness,
    reduceTransparency: LuminaTheme.of(context).reduceTransparency,
    child: DefaultTextStyle(
      style: LuminaTheme.of(context).textTheme.bodyMedium,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: MediaQuery.sizeOf(c).height * .85,
            ),
            child: LuminaSurface(
              glass: true,
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
                      builder(c),
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
);
void showLuminaMessage(BuildContext context, String text) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (c) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(c).bottom + 28,
      child: IgnorePointer(
        child: Center(
          child: DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.bodyMedium,
            child: LuminaSurface(glass: true, child: Text(text)),
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
}) async {
  var date = initialDate;
  var month = DateTime(date.year, date.month);
  return showLuminaDialog<DateTime>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => LuminaDialog(
        title: '选择日期',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                LuminaIconButton(
                  onPressed: () =>
                      set(() => month = DateTime(month.year, month.month - 1)),
                  icon: const LuminaIcon(LuminaIcons.arrowLeft),
                ),
                Expanded(
                  child: Text(
                    '${month.year} / ${month.month}',
                    textAlign: TextAlign.center,
                  ),
                ),
                LuminaIconButton(
                  onPressed: () =>
                      set(() => month = DateTime(month.year, month.month + 1)),
                  icon: const LuminaIcon(LuminaIcons.arrowRight),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: ['一', '二', '三', '四', '五', '六', '日']
                  .map(
                    (day) =>
                        Expanded(child: Text(day, textAlign: TextAlign.center)),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 2,
              mainAxisSpacing: 4,
              children: List.generate(
                DateTime(month.year, month.month + 1, 0).day +
                    month.weekday -
                    1,
                (i) {
                  if (i < month.weekday - 1) return const SizedBox();
                  final d = DateTime(
                    month.year,
                    month.month,
                    i - month.weekday + 2,
                  );
                  final enabled =
                      !d.isBefore(
                        DateTime(
                          firstDate.year,
                          firstDate.month,
                          firstDate.day,
                        ),
                      ) &&
                      !d.isAfter(lastDate);
                  return SizedBox(
                    width: 40,
                    height: 44,
                    child: LuminaSurface(
                      radius: 12,
                      padding: const EdgeInsets.all(4),
                      color:
                          date.year == d.year &&
                              date.month == d.month &&
                              date.day == d.day
                          ? LuminaTheme.of(c).colors.accentSoft
                          : null,
                      onTap: enabled ? () => set(() => date = d) : null,
                      child: Center(
                        child: Text(
                          '${d.day}',
                          style: TextStyle(
                            color: enabled
                                ? LuminaTheme.of(c).colors.ink
                                : LuminaTheme.of(c).colors.muted,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          LuminaButton(
            onPressed: () => Navigator.pop(c, date),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
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
        title: '选择时间',
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final isHour in [true, false])
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LuminaIconButton(
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
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
