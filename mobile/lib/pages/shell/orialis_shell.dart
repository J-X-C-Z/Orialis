import 'package:go_router/go_router.dart';
import '../../app/design/design_components.dart';

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
  Widget build(BuildContext context) {
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
                      // Rebuild when the blur budget changes (auto-downgrade).
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
                            onDragEnd: (index) =>
                                widget.navigationShell.goBranch(index),
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
                                        onTap: () =>
                                            widget.navigationShell.goBranch(
                                              i,
                                              initialLocation:
                                                  i ==
                                                  widget
                                                      .navigationShell
                                                      .currentIndex,
                                            ),
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
