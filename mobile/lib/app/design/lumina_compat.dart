import 'package:lumina_ui/lumina_ui.dart' as ui;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import '../../pages/shared/adaptive_layout.dart';

export 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

/// Desktop chrome is opt-in at the shell; phone routes retain floating headers.
class DesktopLayoutScope extends InheritedWidget {
  const DesktopLayoutScope({required super.child, super.key});
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopLayoutScope>() != null;
  @override
  bool updateShouldNotify(DesktopLayoutScope oldWidget) => false;
}

class OrialisPageScaffold extends StatelessWidget {
  const OrialisPageScaffold({
    required this.title,
    this.body,
    this.bodyBuilder,
    this.controls,
    this.controlsExtent,
    this.adaptiveHeader = true,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottomActions,
    this.floatingActionButton,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    super.key,
  }) : assert((body == null) != (bodyBuilder == null)),
       assert(controls == null || bodyBuilder != null);
  final String title;
  final String? subtitle;
  final Widget? body, controls;
  final double? controlsExtent;
  final bool adaptiveHeader;
  final Widget Function(BuildContext, double)? bodyBuilder;
  final Widget? leading, bottomActions, floatingActionButton;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    if (!DesktopLayoutScope.of(context)) {
      final mainPage =
          leading == null &&
          const {'今日', '事件', '聊天', '日历', '我的'}.contains(title);
      final layoutWide = OrialisAdaptiveLayout.maybeOf(context)?.wide ?? false;
      final wide = adaptiveHeader && layoutWide;
      final sidebar = wide && (!mainPage || controls != null);
      final showHeader = !wide && !(mainPage && layoutWide);
      return LayoutBuilder(
        builder: (context, constraints) {
          final sideWidth =
              80.0 *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                    1.0,
                    1.75,
                  ) +
              MediaQuery.paddingOf(context).left;
          return Row(
            // Keep child slots stable across rotation while placing tools left.
            textDirection: TextDirection.ltr,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: sidebar ? sideWidth : 0,
                child: sidebar
                    ? SafeArea(
                        right: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                          child: LuminaSurface(
                            key: const ValueKey('adaptive-control-rail'),
                            depth: LuminaSurfaceDepth.raised,
                            liquidGlass: false,
                            radius: 28,
                            padding: const EdgeInsets.all(6),
                            child: SingleChildScrollView(
                              key: const ValueKey('adaptive-page-sidebar'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!mainPage) ...[
                                    ?leading,
                                    Text(
                                      title,
                                      textAlign: TextAlign.center,
                                      style: LuminaTheme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    if (subtitle != null) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        subtitle!,
                                        textAlign: TextAlign.center,
                                        style: LuminaTheme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                    for (final action in actions) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.topCenter,
                                        child: action,
                                      ),
                                    ],
                                  ],
                                  if (controls != null) ...[
                                    if (!mainPage) const SizedBox(height: 12),
                                    controls!,
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .removePadding(removeLeft: sidebar),
                  child: LuminaPageScaffold(
                    title: title,
                    showHeader: showHeader,
                    subtitle: subtitle,
                    leading: leading,
                    actions: mainPage ? const [] : actions,
                    bottomActions: bottomActions,
                    floatingActionButton: floatingActionButton,
                    padding: padding,
                    body: controls == null
                        ? body ??
                              Builder(
                                builder: (context) => bodyBuilder!(
                                  context,
                                  showHeader
                                      ? LuminaPageHeaderInset.of(context) + 12
                                      : 0,
                                ),
                              )
                        : LuminaFloatingHeader(
                            showHeader: !wide,
                            horizontalPadding: 12,
                            contentGap: 8,
                            headerExtent: controlsExtent,
                            header: controls!,
                            bodyBuilder: bodyBuilder!,
                          ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
    final theme = LuminaTheme.of(context);
    return ColoredBox(
      color: theme.colors.paper,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 76),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colors.outline.withValues(alpha: .35),
                  ),
                ),
              ),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title == '事件' ? '任务' : title,
                          style: theme.textTheme.titleLarge,
                        ),
                        if (subtitle != null)
                          Text(subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Expanded(
              child: LuminaPageHeaderInset(
                inset: 0,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          padding: EdgeInsets.only(
                            bottom:
                                LuminaNavigationInset.of(context) +
                                MediaQuery.paddingOf(context).bottom,
                          ),
                        ),
                        child: Padding(
                          padding: padding,
                          child: body ?? bodyBuilder!(context, 0),
                        ),
                      ),
                    ),
                    if (floatingActionButton != null)
                      Positioned(
                        right: 24,
                        bottom: 24,
                        child: floatingActionButton!,
                      ),
                  ],
                ),
              ),
            ),
            ?bottomActions,
          ],
        ),
      ),
    );
  }
}

typedef OrialisTopBar = LuminaTopBar;
typedef OrialisListRow = LuminaListRow;
typedef OrialisSection = LuminaSection;
typedef OrialisSectionHeader = LuminaSectionHeader;
typedef OrialisBottomActionBar = LuminaBottomActionBar;
typedef OrialisEmptyState = LuminaEmptyState;
typedef OrialisChatBubble = LuminaChatBubble;
typedef AppColors = LuminaBaseColors;
typedef AppSpacing = LuminaSpacing;
typedef AppRadius = LuminaRadius;
typedef AppCardMetrics = LuminaCardMetrics;
typedef AppControlSize = LuminaControlSize;
typedef AppIconSize = LuminaIconSize;
typedef AppChatMetrics = LuminaChatMetrics;

class LuminaConversationVisibility extends Notification {
  const LuminaConversationVisibility(this.open);
  final bool open;
}

/// Loaded before first paint so remembered folds do not flash open on launch.
class LuminaCardMemory {
  static SharedPreferences? _preferences;
  static String? get selectedProject =>
      _preferences?.getString('lumina.project.expanded');
  static void selectProject(String? id) {
    final preferences = _preferences;
    if (preferences == null) return;
    unawaited(
      _persist(
        id == null
            ? preferences.remove('lumina.project.expanded')
            : preferences.setString('lumina.project.expanded', id),
      ),
    );
  }

  static Future<void> initialize() async {
    LuminaHaptics.effectHandler = (effect) =>
        const MethodChannel('top.jxcz.orialis/haptics')
            .invokeMethod<void>(effect);
    LuminaHaptics.selectionHandler = null;
    LuminaHaptics.confirmHandler = null;
    try {
      _preferences = await SharedPreferences.getInstance();
      ui.LuminaCardMemory.store = _PreferencesCardStore(_preferences!);
    } catch (_) {}
  }

  static bool expanded(String id, {bool fallback = true}) =>
      _preferences?.getBool('lumina.card.$id') ?? fallback;
  static void save(String id, bool value) {
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(_persist(preferences.setBool('lumina.card.$id', value)));
    }
  }

  static Future<void> _persist(Future<bool> operation) async {
    try {
      await operation;
    } catch (_) {
      // A preference write failure must not undo or interrupt a user's fold.
    }
  }
}

class _PreferencesCardStore implements LuminaCardStore {
  _PreferencesCardStore(this.preferences);
  final SharedPreferences preferences;
  @override
  bool? readExpanded(String id) => preferences.getBool('lumina.card.$id');
  @override
  Future<void> writeExpanded(String id, bool expanded) async {
    await preferences.setBool('lumina.card.$id', expanded);
  }
}
