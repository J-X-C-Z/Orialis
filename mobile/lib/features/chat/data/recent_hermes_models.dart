import 'package:shared_preferences/shared_preferences.dart';

/// Models successfully selected in Hermes, newest first, on this device.
///
/// Call [recordSuccessfulSwitch] only after Hermes confirms the model change.
/// Attempted switches must not be recorded as successful history.
class RecentHermesModels {
  RecentHermesModels({SharedPreferences? preferences, this.accountScope})
    : _preferences = preferences;

  static const maxEntries = 5;
  static const storageKey = 'orialis.chat.recentHermesModels';

  final SharedPreferences? _preferences;
  final Future<String> Function()? accountScope;

  Future<String> get _key async => accountScope == null
      ? storageKey
      : '$storageKey:${await accountScope!()}';
  Future<void> _pendingWrite = Future<void>.value();

  Future<SharedPreferences> get _store async =>
      _preferences ?? SharedPreferences.getInstance();

  Future<List<String>> load() async {
    final key = await _key;
    await _pendingWrite;
    final preferences = await _store;
    return _normalise(preferences.getStringList(key) ?? const []);
  }

  Future<void> recordSuccessfulSwitch(String model) async {
    final selected = model.trim();
    if (selected.isEmpty) return Future<void>.value();

    final key = await _key;
    // A rapid second selection must observe the first write before updating
    // the persisted list. Keep the queue usable if an earlier write failed.
    final write = _pendingWrite.catchError((Object _) {}).then((_) async {
      final preferences = await _store;
      final existing = _normalise(preferences.getStringList(key) ?? const []);
      final updated = _normalise([selected, ...existing]);
      await preferences.setStringList(key, updated);
    });
    _pendingWrite = write;
    return write;
  }

  static List<String> _normalise(List<String> values) {
    final result = <String>[];
    for (final value in values) {
      final model = value.trim();
      if (model.isEmpty || result.contains(model)) continue;
      result.add(model);
      if (result.length == maxEntries) break;
    }
    return result;
  }
}
