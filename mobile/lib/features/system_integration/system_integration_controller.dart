import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/database/app_database.dart';
import 'system_snapshot.dart';

class SystemIntegrationController {
  SystemIntegrationController({
    required this.database,
    required this.config,
    this.onRoute,
    MethodChannel? channel,
    bool? supported,
  }) : channel = channel ?? const MethodChannel('top.jxcz.orialis/system'),
       supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const scopeKey = 'system_integration.scope';
  static const enabledKey = 'systemIntegrationEnabled';
  final AppDatabase database;
  final AppConfig config;
  final MethodChannel channel;
  final bool supported;
  void Function(String route)? onRoute;
  bool enabled = false;
  bool identityCompatible = false;
  bool _started = false;
  bool _disposed = false;
  bool _identityChanging = false;
  bool _dirty = false;
  Future<void>? _running;
  Future<void>? _claiming;
  Future<void>? _starting;
  int _generation = 0;
  Timer? _midnight;
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Future<T?> _invoke<T>(
    String method, [
    Object? arguments,
    bool propagate = false,
  ]) async {
    if (!supported) return null;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      if (propagate) rethrow;
      return null;
    } on PlatformException {
      if (propagate) rethrow;
      return null;
    }
  }

  Future<String?> _scope() async {
    final token = await config.sessionToken();
    final username = await config.sessionUsername();
    if (token == null ||
        token.isEmpty ||
        username == null ||
        username.isEmpty) {
      return null;
    }
    final server = (await config.serverUrl()).replaceFirst(RegExp(r'/+$'), '');
    return sha256
        .convert(utf8.encode(jsonEncode([server, username])))
        .toString();
  }

  Future<String?> _marker() async => (await (database.select(
    database.syncMetadata,
  )..where((row) => row.key.equals(scopeKey))).getSingleOrNull())?.value;

  Future<void> start() {
    if (_disposed || !supported) return Future.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    enabled =
        (await SharedPreferences.getInstance()).getBool(enabledKey) ?? false;
    if (_disposed) return;
    _started = true;
    config.addIdentityListener(_identityWillChange);
    config.addIdentityCommittedListener(_identityDidChange);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openRoute') await _route(call.arguments);
    });
    _subscriptions.add(
      database.watchActiveTasks().listen((_) => unawaited(refresh())),
    );
    _subscriptions.add(
      database.watchActiveCalendarEvents().listen((_) => unawaited(refresh())),
    );
    _scheduleMidnight();
    // Clear may discard a native pending scoped intent. Read it first, then
    // validate it against the refreshed identity; anonymous shortcuts survive.
    final initialRoute = await _invoke<Object?>('initialRoute');
    await refresh();
    await _route(initialRoute);
  }

  Future<void> _route(Object? arguments) async {
    if (_disposed || arguments is! Map) return;
    final route = arguments['route'];
    if (route is! String) return;
    if ((arguments['scope'] == null || arguments['scope'] == '') &&
        const ['/today', '/events', '/calendar'].contains(route)) {
      onRoute?.call(route);
      return;
    }
    if (_identityChanging || !enabled) return;
    final generation = _generation;
    final scope = await _scope();
    if (scope == null ||
        arguments['scope'] != scope ||
        await _marker() != scope) {
      return;
    }
    if (_disposed || _identityChanging || generation != _generation) return;
    final uri = Uri.tryParse(route);
    if (uri == null || uri.hasAuthority || uri.hasScheme) return;
    if (route == '/today' ||
        route == '/events' ||
        route == '/calendar' ||
        (uri.pathSegments.length == 3 &&
            uri.pathSegments[0] == 'calendar' &&
            uri.pathSegments[1] == 'schedule')) {
      onRoute?.call(route);
    }
  }

  Future<void> _identityWillChange() async {
    _identityChanging = true;
    _generation++;
    // Wait for an in-flight publish before clearing, so it cannot republish
    // old account data after the clear operation.
    await _claiming;
    await _running;
    await _invoke<void>('clear');
    identityCompatible = false;
  }

  Future<void> _identityDidChange() async {
    _identityChanging = false;
    await refresh();
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed || !supported) return;
    if (value && !_identityChanging) {
      await (_claiming ??= _claimScope().whenComplete(() => _claiming = null));
    }
    enabled = value;
    await (await SharedPreferences.getInstance()).setBool(enabledKey, value);
    _generation++;
    await refresh();
  }

  Future<void> _claimScope() async {
    final generation = _generation;
    final scope = await _scope();
    if (scope == null ||
        _disposed ||
        _identityChanging ||
        generation != _generation) {
      return;
    }
    await database.transaction(() async {
      if (await _marker() != null) return;
      // The shared DB has no per-row account attribution. Consent to display
      // cannot establish ownership of existing rows, including deleted rows.
      final existing = await database.customSelect('''
        SELECT 1 FROM tasks
        UNION ALL SELECT 1 FROM calendar_events
        UNION ALL SELECT 1 FROM projects
        UNION ALL SELECT 1 FROM project_milestones
        UNION ALL SELECT 1 FROM conversations
        UNION ALL SELECT 1 FROM messages
        LIMIT 1
      ''').get();
      if (_disposed || _identityChanging || generation != _generation) return;
      await database
          .into(database.syncMetadata)
          .insert(
            SyncMetadataCompanion.insert(
              key: scopeKey,
              value: existing.isEmpty ? scope : 'identity-unverified',
            ),
          );
    });
  }

  Future<void> refresh() {
    if (_disposed || !supported) return Future.value();
    _dirty = true;
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      final generation = _generation;
      try {
        final scope = await _scope();
        var marker = await _marker();
        // Observe the first authenticated identity even before opt in, so a
        // later account switch cannot relabel its shared rows as the new user.
        if (scope != null && marker == null) {
          await _claimScope();
          marker = await _marker();
        }
        if (_disposed || _identityChanging || generation != _generation) {
          identityCompatible = false;
          await _invoke<void>('clear');
          continue;
        }
        // The mobile database is shared. Once another authenticated identity
        // has used it, switching back cannot establish that its rows are safe.
        // This marker is deliberately irreversible within this feature.
        if (scope != null &&
            marker != null &&
            marker != scope &&
            marker != 'identity-unverified') {
          marker = 'identity-unverified';
          await database
              .into(database.syncMetadata)
              .insertOnConflictUpdate(
                SyncMetadataCompanion.insert(key: scopeKey, value: marker),
              );
        }
        identityCompatible = scope != null && marker == scope;
        if (!enabled || _identityChanging || !identityCompatible) {
          await _invoke<void>('clear');
          continue;
        }
        final snapshot = await database.transaction(
          () async => buildSystemSnapshot(
            scope: scope!,
            tasks: await database.select(database.tasks).get(),
            events: await database.select(database.calendarEvents).get(),
            now: DateTime.now(),
          ),
        );
        if (_disposed || _identityChanging || generation != _generation) {
          continue;
        }
        await _invoke<void>('updateSnapshot', snapshot, true);
      } catch (_) {
        // A closed database or unavailable native bridge must not break sync
        // or the rest of the app. Do not retain potentially stale reminders.
        await _invoke<void>('clear');
      }
    }
  }

  void _scheduleMidnight() {
    final now = DateTime.now();
    _midnight = Timer(
      DateTime(now.year, now.month, now.day + 1).difference(now),
      () {
        if (_disposed) return;
        unawaited(refresh());
        _scheduleMidnight();
      },
    );
  }

  Future<Map<Object?, Object?>?> status() =>
      _invoke<Map<Object?, Object?>>('status');
  Future<bool?> requestNotifications() => _invoke<bool>('requestNotifications');
  Future<void> openNotificationSettings() =>
      _invoke<void>('openNotificationSettings');
  Future<bool?> requestPinWidget() => _invoke<bool>('requestPinWidget');
  Future<bool?> previewReminder() => _invoke<bool>('previewReminder');
  Future<void> openExactAlarmSettings() =>
      _invoke<void>('openExactAlarmSettings');

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _midnight?.cancel();
    config.removeIdentityListener(_identityWillChange);
    config.removeIdentityCommittedListener(_identityDidChange);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    if (_started) channel.setMethodCallHandler(null);
    await _claiming;
    await _running;
  }
}
