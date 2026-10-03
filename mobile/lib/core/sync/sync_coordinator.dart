import 'dart:async';

import '../realtime/mobile_realtime_client.dart';
import '../../features/chat/data/chat_repository.dart';
import 'sync_engine.dart';

/// Application-owned sync lifecycle. Requests are single-flight and coalesced
/// so reconnects, change hints, and user actions cannot run overlapping pulls.
class SyncCoordinator {
  SyncCoordinator({
    required this.sync,
    required this.realtime,
    this.chatRepository,
    this.localChanges,
    this.onChatMessage,
    this.onScheduleUpdate,
    this.localChangeDelay = const Duration(milliseconds: 250),
  });

  final Future<SyncState> Function() sync;
  final MobileRealtimeClient realtime;
  final ChatRepository? chatRepository;
  final Stream<void>? localChanges;
  final Future<void> Function(Map<String, dynamic>)? onChatMessage;
  final Future<void> Function(Map<String, dynamic>)? onScheduleUpdate;
  final Duration localChangeDelay;
  StreamSubscription<MobileEnvelope>? _events;
  StreamSubscription<void>? _localChanges;
  Timer? _localChangeTimer;
  Future<SyncState>? _inFlight;
  bool _queued = false;
  bool _started = false;
  bool _disposed = false;

  static bool isSyncTriggerType(String type) =>
      type == 'hello.ack' ||
      type == 'sync.change_hint' ||
      type == 'change_hint' ||
      type == 'change.hint';

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _events = realtime.events.listen(_onEvent);
    _localChanges = localChanges?.listen((_) {
      _localChangeTimer?.cancel();
      _localChangeTimer = Timer(localChangeDelay, () {
        _localChangeTimer = null;
        if (!_disposed) unawaited(requestSync());
      });
    });
    unawaited(realtime.connect().catchError((_) {}));
    await requestSync();
  }

  Future<SyncState> requestSync() {
    if (_disposed) return Future.value(SyncState.error);
    final active = _inFlight;
    if (active != null) {
      _queued = true;
      return active;
    }
    final future = _runSync();
    _inFlight = future;
    return future;
  }

  Future<SyncState> _runSync() async {
    try {
      return await sync();
    } finally {
      _inFlight = null;
      if (_queued && !_disposed) {
        _queued = false;
        unawaited(requestSync());
      }
    }
  }

  void _onEvent(MobileEnvelope event) {
    if (event.type == 'message') {
      final repository = chatRepository;
      if (repository != null) {
        unawaited(() async {
          await repository.applyRemoteMessage(event.payload);
          await onChatMessage?.call(event.payload);
        }());
      } else {
        final notify = onChatMessage;
        if (notify != null) unawaited(notify(event.payload));
      }
      return;
    }
    if (event.type == 'schedule.updated') {
      unawaited(() async {
        final state = await requestSync();
        if (!_disposed && state == SyncState.idle) {
          await onScheduleUpdate?.call(event.payload);
        }
      }());
      return;
    }
    if (isSyncTriggerType(event.type)) {
      unawaited(requestSync());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _localChangeTimer?.cancel();
    _localChangeTimer = null;
    await _localChanges?.cancel();
    _localChanges = null;
    await _events?.cancel();
    _events = null;
    // Finish old-account work before its database and credentials are changed.
    await _inFlight;
  }
}
