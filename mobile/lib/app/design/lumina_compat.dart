import 'package:lumina_ui/lumina_ui.dart' as ui;
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
export 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

typedef OrialisPageScaffold = LuminaPageScaffold;
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
