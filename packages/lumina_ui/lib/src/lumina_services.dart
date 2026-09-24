import 'dart:async';

/// Optional host persistence. Implement this using any synchronous read cache.
abstract interface class LuminaCardStore {
  bool? readExpanded(String id);
  FutureOr<void> writeExpanded(String id, bool expanded);
}

/// Default session-only storage; no plugins, disk access or initialization.
class LuminaMemoryCardStore implements LuminaCardStore {
  final Map<String, bool> _values = {};
  @override
  bool? readExpanded(String id) => _values[id];
  @override
  void writeExpanded(String id, bool expanded) => _values[id] = expanded;
}

class LuminaCardMemory {
  static LuminaCardStore store = LuminaMemoryCardStore();
  static bool expanded(String id, {bool fallback = true}) =>
      store.readExpanded(id) ?? fallback;
  static void save(String id, bool value) {
    unawaited(_save(id, value));
  }

  static Future<void> _save(String id, bool value) async {
    try {
      await store.writeExpanded(id, value);
    } catch (_) {
      // Persistence failure must not reverse a successful UI interaction.
    }
  }
}
