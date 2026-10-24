import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/config/app_config.dart';
import '../data/memory_repository.dart';
import '../domain/memory_record.dart';
import 'memory_analyzer.dart';

/// Starts analysis only for memories explicitly captured or shared by the user.
class MemoryCoordinator {
  MemoryCoordinator({
    required this.config,
    required this.repository,
    required this.analyzer,
  });

  final AppConfig config;
  final MemoryRepository repository;
  final MemoryAnalyzer analyzer;
  void Function(String route)? onRoute;
  void Function()? onScopeWillChange;
  bool _started = false;
  bool _disposed = false;
  bool _rescan = false;
  int _generation = 0;
  String? _scope;
  Future<void>? _draining;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    if (!(await repository.status()).supported || _disposed) return;
    config.addIdentityListener(_revoke);
    config.addIdentityCommittedListener(_restore);
    repository.channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'memoryRoute') onRoute?.call('/memory');
      if (call.method == 'memoryChanged' || call.method == 'memoryRoute') {
        repository.refresh();
        unawaited(scan());
      }
    });
    await _restore();
    if (_disposed) return;
    final pending = await repository.channel.invokeMethod<String>(
      'takePendingRoute',
    );
    if (!_disposed && pending == '/memory') onRoute?.call(pending!);
  }

  Future<void> _revoke() async {
    _generation++;
    _scope = null;
    onScopeWillChange?.call();
    await repository.setScope(null);
    repository.refresh();
  }

  Future<void> _restore() async {
    final generation = _generation;
    final token = await config.sessionToken();
    final username = await config.sessionUsername();
    final name = await config.desktopDatabaseName();
    if (_disposed || generation != _generation) return;
    _scope =
        token == null || token.isEmpty || username == null || username.isEmpty
        ? null
        : sha256.convert(utf8.encode(name)).toString();
    await repository.setScope(_scope);
    if (_disposed || generation != _generation) return;
    repository.refresh();
    unawaited(scan());
  }

  Future<void> resume() async {
    if (!_started || _disposed || _scope == null) return;
    repository.refresh();
    await scan();
  }

  Future<void> retry(MemoryRecord record) async {
    if (_disposed || _scope == null) return;
    final generation = _generation;
    final active = _draining;
    if (active != null) await active;
    if (_disposed || _scope == null || generation != _generation) return;
    await analyzer.analyze(
      record,
      retry: true,
      isCurrent: () => !_disposed && generation == _generation,
    );
  }

  Future<void> scan() {
    if (_disposed || _scope == null) return Future.value();
    final active = _draining;
    if (active != null) {
      _rescan = true;
      return active;
    }
    return _draining = _drain();
  }

  Future<void> _drain() async {
    final generation = _generation;
    bool current() => !_disposed && generation == _generation;
    try {
      do {
        _rescan = false;
        final records = await repository.list();
        for (final record in records.reversed) {
          if (!current()) return;
          if (record.analysisStatus == 'pending' ||
              record.analysisStatus == 'analyzing') {
            await analyzer.analyze(record, isCurrent: current);
          }
        }
      } while (_rescan && current());
    } catch (_) {
      // A removed record or unavailable platform must not break the app shell.
    } finally {
      _draining = null;
      if (_rescan && !_disposed) unawaited(scan());
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    config.removeIdentityListener(_revoke);
    config.removeIdentityCommittedListener(_restore);
    repository.channel.setMethodCallHandler(null);
  }
}
