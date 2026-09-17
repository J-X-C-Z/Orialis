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
    required this.chatRepository,
  });

  final Future<SyncState> Function() sync;
  final MobileRealtimeClient realtime;
  final ChatRepository chatRepository;
  StreamSubscription<MobileEnvelope>? _events;
  Future<SyncState>? _inFlight;
  bool _queued = false;
  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _events = realtime.events.listen(_onEvent);
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
      unawaited(chatRepository.applyRemoteMessage(event.payload));
      return;
    }
    if (event.type == 'hello.ack' ||
        event.type == 'change_hint' ||
        event.type == 'change.hint') {
      unawaited(requestSync());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _events?.cancel();
    _events = null;
  }
}
