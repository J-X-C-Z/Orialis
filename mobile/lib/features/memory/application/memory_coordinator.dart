import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/config/app_config.dart';
import '../data/memory_repository.dart';
import '../domain/memory_record.dart';
import 'memory_analyzer.dart';
import 'memory_cloud_sync.dart';

/// Starts analysis only for memories explicitly captured or shared by the user.
class MemoryCoordinator {
  MemoryCoordinator({
    required this.config,
    required this.repository,
    required this.analyzer,
    this.cloudSync,
  });

  final AppConfig config;
  final MemoryRepository repository;
  final MemoryAnalyzer analyzer;
  final MemoryCloudSync? cloudSync;
  void Function(String route)? onRoute;
  void Function()? onScopeWillChange;
  void Function(String message)? onCaptureError;
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
    cloudSync?.start(() => !_disposed && _scope != null);
    config.addIdentityListener(_revoke);
    config.addIdentityCommittedListener(_restore);
    repository.channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'captureError') {
        final arguments = call.arguments;
        final message = arguments is Map ? arguments['message'] : null;
        onCaptureError?.call(message is String ? message : '记忆未能记录，请检查系统授权');
        return;
      }
      if (call.method == 'memoryRoute') onRoute?.call('/memory');
      if (call.method == 'memoryChanged' || call.method == 'memoryRoute') {
        repository.refresh();
        final arguments = call.arguments;
        final id = arguments is Map ? arguments['id'] : null;
        if (id is String) unawaited(_submitChanged(id));
        unawaited(scan());
      }
    });
    await _restore();
    if (_disposed) return;
    final pending = await repository.takePendingRoute();
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
    unawaited(cloudSync?.sync());
    unawaited(scan());
  }

  Future<void> resume() async {
    if (!_started || _disposed || _scope == null) return;
    repository.refresh();
    await cloudSync?.sync();
    await scan();
  }

  Future<void> _submitChanged(String id) async {
    final generation = _generation;
    bool current() => !_disposed && _scope != null && generation == _generation;
    try {
      if (!current()) return;
      final record = await repository.read(id);
      if (record.analysisStatus != 'pending' ||
          record.analysisRequestId != null ||
          !current()) {
        return;
      }
      await analyzer.analyze(record, isCurrent: current);
    } catch (_) {
      // The scheduled background job also drains saved records.
    }
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
    final attempted = <String>{};
    try {
      do {
        _rescan = false;
        final records = await repository.list();
        final submitted = <String>{};
        // Upload new evidence before waiting for any earlier model response.
        for (final record in records.reversed) {
          if (!current()) return;
          if (!attempted.add(record.id)) continue;
          if (record.analysisStatus == 'pending' ||
              record.analysisStatus == 'analyzing' ||
              (record.analysisStatus == 'completed' &&
                  record.category == null)) {
            await analyzer.analyze(
              record,
              submitOnly: true,
              isCurrent: current,
            );
            submitted.add(record.id);
          }
        }
        for (final record in records.reversed) {
          if (!current()) return;
          if (submitted.contains(record.id)) {
            final latest = await repository.read(record.id);
            if (latest.analysisStatus == 'analyzing') {
              await analyzer.analyze(latest, isCurrent: current);
            }
          }
        }
      } while (_rescan && current());
      if (current()) await cloudSync?.sync();
    } catch (_) {
      // A removed record or unavailable platform must not break the app shell.
    } finally {
      _draining = null;
      if (_rescan && !_disposed) unawaited(scan());
    }
  }

  void dispose() {
    _disposed = true;
    cloudSync?.dispose();
    _generation++;
    config.removeIdentityListener(_revoke);
    config.removeIdentityCommittedListener(_restore);
    repository.channel.setMethodCallHandler(null);
  }
}
