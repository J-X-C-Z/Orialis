import 'package:lumina_ui/lumina_ui.dart' as ui;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
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
    required this.body,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottomActions,
    this.floatingActionButton,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? leading, bottomActions, floatingActionButton;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    if (!DesktopLayoutScope.of(context)) {
      return LuminaPageScaffold(
        title: title,
        body: body,
        subtitle: subtitle,
        leading: leading,
        actions: actions,
        bottomActions: bottomActions,
        floatingActionButton: floatingActionButton,
        padding: padding,
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
                        child: Padding(padding: padding, child: body),
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
    LuminaHaptics.confirmHandler = () async {
      try {
        await const MethodChannel(
          'top.jxcz.orialis/haptics',
        ).invokeMethod<void>('confirm');
      } on MissingPluginException {
        await HapticFeedback.lightImpact();
      } on PlatformException {
        /* Unavailable haptics must not interrupt UI. */
      }
    };
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
