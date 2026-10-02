import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'wear_protocol.dart';
import 'wear_snapshot_producer.dart';
import 'wear_transport.dart';

class WearConnectionState {
  const WearConnectionState({
    this.diagnostics = const WearDiagnostics(),
    this.busy = false,
    this.phone = WearPresence.unknown,
    this.selectedNode,
    this.delivery = '尚未发送',
    this.error,
    this.snapshot,
  });
  final WearDiagnostics diagnostics;
  final bool busy;
  final WearPresence phone;
  // Orialis and Target availability require independent observations. There is
  // currently no live Node/Control integration, so neither is inferred here.
  WearPresence get orialis => WearPresence.unknown;
  WearPresence get target => WearPresence.unknown;
  final String? selectedNode, error;
  final String delivery;
  final WearSnapshotPreview? snapshot;
}

class _Pending {
  _Pending(this.kind, this.id, this.revision, this.node, this.session);
  final String kind, id, node, session;
  final int? revision;
  final response = Completer<String>();
  Timer? timer;
  String? result;
  void complete(String result) {
    timer?.cancel();
    if (!response.isCompleted) {
      this.result = result;
      response.complete(result);
    }
  }
}

/// No replay queue or outbound disk cache. Every send is bound to the current
/// selected wearable, native session and identity generation.
class WearConnectionManager extends StateNotifier<WearConnectionState> {
  WearConnectionManager(
    this.transport, {
    this.responseTimeout = const Duration(seconds: 10),
    this.snapshotLoader,
  }) : super(const WearConnectionState()) {
    _messages = transport.messages.listen(_receive, onError: _streamError);
    _diagnostics = transport.diagnostics.listen(
      _observe,
      onError: _streamError,
    );
  }
  final WearTransport transport;
  final Duration responseTimeout;
  final Future<WearSnapshotPreview> Function()? snapshotLoader;
  late final StreamSubscription<WearMessage> _messages;
  late final StreamSubscription<WearDiagnostics> _diagnostics;
  _Pending? _pending;
  int _generation = 0;
  int _operationSerial = 0;
  bool _acceptEvents = true;

  void _set({
    WearDiagnostics? diagnostics,
    bool? busy,
    WearPresence? phone,
    String? selectedNode,
    String? delivery,
    String? error,
    bool clearNode = false,
    WearSnapshotPreview? snapshot,
    bool clearSnapshot = false,
  }) {
    if (!mounted) return;
    state = WearConnectionState(
      diagnostics: diagnostics ?? state.diagnostics,
      busy: busy ?? state.busy,
      phone: phone ?? state.phone,
      selectedNode: clearNode ? null : selectedNode ?? state.selectedNode,
      delivery: delivery ?? state.delivery,
      error: error,
      snapshot: clearSnapshot ? null : snapshot ?? state.snapshot,
    );
  }

  void _streamError(Object error) {
    if (!_acceptEvents) return;
    _pending?.complete('transport_error');
    _set(phone: WearPresence.unknown, error: 'transport_error');
  }

  void _observe(WearDiagnostics diagnostics) {
    if (!mounted || !_acceptEvents) return;
    final changed =
        diagnostics.session != state.diagnostics.session ||
        (state.selectedNode != null &&
            !diagnostics.nodeIds.contains(state.selectedNode)) ||
        (state.diagnostics.canMessageFor(state.selectedNode) &&
            !diagnostics.canMessageFor(state.selectedNode));
    final cancelledSend = changed && _pending != null;
    if (changed) {
      _generation++;
      _pending?.complete('session_changed');
      _pending = null;
    }
    _set(
      diagnostics: diagnostics,
      clearSnapshot: changed,
      busy: cancelledSend ? false : null,
      clearNode: !diagnostics.nodeIds.contains(state.selectedNode),
      phone: changed ? WearPresence.unknown : null,
      delivery: cancelledSend ? '会话已变更；未确认送达' : null,
      error:
          diagnostics.lastError ?? (cancelledSend ? 'session_changed' : null),
    );
  }

  Future<void> _operation(
    Future<WearDiagnostics> Function() operation, {
    Duration? timeout,
  }) async {
    if (state.busy) return;
    final generation = _generation;
    final serial = ++_operationSerial;
    _acceptEvents = true;
    _set(busy: true);
    try {
      final result = await operation().timeout(timeout ?? responseTimeout);
      if (mounted && generation == _generation) _observe(result);
    } catch (_) {
      if (mounted && generation == _generation) _set(error: 'transport_error');
    } finally {
      if (mounted && serial == _operationSerial) {
        _set(busy: false, error: state.error);
      }
    }
  }

  Future<void> connect() async {
    if (state.busy) return;
    _acceptEvents = true;
    await _operation(transport.connect);
  }

  Future<void> refresh() => _operation(transport.refresh);
  Future<void> requestPermissions() => _operation(
    transport.requestPermissions,
    timeout: const Duration(seconds: 65),
  );

  /// Called before account/server changes, disconnect and local unbinding.
  Future<void> revokeSession() async {
    ++_generation;
    ++_operationSerial;
    _acceptEvents = false;
    _pending?.complete('session_revoked');
    _pending = null;
    if (mounted) {
      state = WearConnectionState(
        diagnostics: WearDiagnostics(
          availability: state.diagnostics.availability,
        ),
        phone: WearPresence.offline,
        delivery: '会话已撤销；不会自动重发',
      );
    }
    try {
      await transport.disconnect().timeout(responseTimeout);
    } catch (_) {
      if (mounted) _set(error: 'disconnect_failed');
    }
  }

  Future<void> selectNode(String node) async {
    if (!state.diagnostics.nodeIds.contains(node) || state.busy) return;
    ++_generation;
    _pending?.complete('target_changed');
    _pending = null;
    _set(
      selectedNode: node,
      clearSnapshot: true,
      phone: WearPresence.unknown,
      delivery: '已切换手环；尚未发送',
    );
    await _operation(() => transport.selectNode(node));
  }

  Future<void> openApp() async {
    if (state.busy || state.selectedNode == null) return;
    _set(busy: true);
    final generation = _generation;
    try {
      await transport.openApp().timeout(responseTimeout);
      if (mounted && generation == _generation) _set(delivery: '已请求打开手环应用');
    } catch (_) {
      if (mounted && generation == _generation) _set(error: 'launch_failed');
    } finally {
      if (mounted && generation == _generation) {
        _set(busy: false, error: state.error);
      }
    }
  }

  Future<void> ping() => _send('pong', null);

  /// Produces only on a user action. Identity/target/session invalidation wins
  /// over every asynchronous read; stale results never reappear in the page.
  Future<void> refreshSnapshot() async {
    final loader = snapshotLoader;
    if (state.busy || loader == null) return;
    final generation = _generation;
    final serial = ++_operationSerial;
    _set(busy: true, clearSnapshot: true);
    try {
      final preview = await loader();
      if (!mounted || generation != _generation) return;
      _set(snapshot: preview);
    } catch (_) {
      if (mounted && generation == _generation) {
        _set(error: 'snapshot_read_failed', clearSnapshot: true);
      }
    } finally {
      if (mounted && serial == _operationSerial) {
        _set(busy: false, error: state.error);
      }
    }
  }

  Future<void> sendCurrentSnapshot() async {
    final loader = snapshotLoader;
    if (state.busy ||
        loader == null ||
        !state.diagnostics.canMessageFor(state.selectedNode)) {
      _set(error: 'connection_not_ready');
      return;
    }
    if (state.snapshot?.accountScopeVerified != true) {
      _set(error: 'account_scope_unverified');
      return;
    }
    final generation = _generation;
    final serial = ++_operationSerial;
    final node = state.selectedNode, session = state.diagnostics.session;
    _set(busy: true);
    try {
      // Re-read instead of sending an older preview. There is no replay queue.
      final preview = await loader();
      if (!mounted ||
          generation != _generation ||
          node != state.selectedNode ||
          session != state.diagnostics.session) {
        return;
      }
      if (!preview.accountScopeVerified) {
        _set(error: 'account_scope_unverified');
        return;
      }
      _set(snapshot: preview, busy: false);
      await _send('snapshot.ack', preview.snapshot);
    } catch (_) {
      if (mounted && generation == _generation) {
        _set(error: 'snapshot_read_failed');
      }
    } finally {
      if (mounted && serial == _operationSerial) {
        _set(busy: false, error: state.error);
      }
    }
  }

  /// Low-level W0 codec/ACK seam; production UI uses sendCurrentSnapshot.
  Future<void> sendSnapshot(Map<String, Object?> snapshot) =>
      _send('snapshot.ack', snapshot);

  Future<void> _send(String kind, Map<String, Object?>? snapshot) async {
    final node = state.selectedNode, session = state.diagnostics.session;
    if (state.busy ||
        _pending != null ||
        !state.diagnostics.canMessageFor(state.selectedNode) ||
        node == null ||
        session == null) {
      _set(error: 'connection_not_ready');
      return;
    }
    List<String> frames;
    final id = kind == 'pong' ? const Uuid().v4() : snapshot?['transferId'];
    try {
      frames = kind == 'pong'
          ? [
              WearProtocol.encode('ping', {
                'pingId': id,
                'sentAt': DateTime.now().toUtc().toIso8601String(),
              }),
            ]
          : WearProtocol.splitSnapshot(snapshot!);
    } catch (_) {
      _set(error: 'invalid_snapshot');
      return;
    }
    final pending = _Pending(
      kind,
      id as String,
      snapshot?['revision'] as int?,
      node,
      session,
    );
    _pending = pending;
    final generation = _generation;
    _set(busy: true, delivery: '发送中…');
    pending.timer = Timer(
      responseTimeout,
      () => pending.complete('response_timeout'),
    );
    try {
      for (final frame in frames) {
        if (pending.result != null && pending.result != 'ok') break;
        if (generation != _generation || !mounted) return;
        await transport.send(node, session, frame).timeout(responseTimeout);
      }
      if (generation != _generation || !mounted) return;
      _set(delivery: kind == 'pong' ? '已交给传输层 · 等待 Pong' : '正在等待手环保存确认');
      final response = await pending.response.future;
      if (generation != _generation || !mounted) return;
      if (response == 'ok') {
        _set(
          phone: kind == 'pong' ? WearPresence.online : null,
          delivery: kind == 'pong' ? '已收到关联 Pong' : '同步完成 · 手环已保存',
        );
      } else {
        _set(delivery: '未确认送达', error: response);
      }
    } catch (_) {
      if (generation == _generation && mounted) {
        _set(delivery: '传输失败', error: 'transport_error');
      }
    } finally {
      pending.complete('cancelled');
      if (identical(_pending, pending)) {
        _pending = null;
        _set(busy: false, error: state.error);
      }
    }
  }

  void _receive(WearMessage message) {
    if (!_acceptEvents ||
        !mounted ||
        !state.diagnostics.canMessageFor(state.selectedNode) ||
        message.nodeId != state.selectedNode ||
        message.session != state.diagnostics.session) {
      return;
    }
    try {
      final frame = WearProtocol.decode(message.data);
      final payload = Map<String, dynamic>.from(frame['payload'] as Map);
      if (frame['type'] == 'ping') {
        final pingId = payload['pingId'];
        if (pingId is! String || pingId.isEmpty || pingId.length > 96) return;
        unawaited(_replyPong(message, pingId, _generation));
        return;
      }
      final pending = _pending;
      if (pending == null ||
          pending.kind != frame['type'] ||
          pending.node != message.nodeId ||
          pending.session != message.session) {
        return;
      }
      if ((pending.kind == 'pong' && payload['pingId'] == pending.id) ||
          (pending.kind == 'snapshot.ack' &&
              payload['transferId'] == pending.id &&
              payload['revision'] == pending.revision)) {
        pending.complete('ok');
      }
    } catch (_) {
      _set(error: 'invalid_message');
    }
  }

  Future<void> _replyPong(
    WearMessage message,
    String pingId,
    int generation,
  ) async {
    try {
      await transport
          .send(
            message.nodeId,
            message.session,
            WearProtocol.encode('pong', {'pingId': pingId}),
          )
          .timeout(responseTimeout);
      if (mounted && generation == _generation) {
        _set(delivery: '已响应手环连接检查');
      }
    } catch (_) {
      if (mounted && generation == _generation) _set(error: 'transport_error');
    }
  }

  @override
  void dispose() {
    _acceptEvents = false;
    ++_generation;
    _pending?.complete('disposed');
    _pending = null;
    unawaited(_messages.cancel());
    unawaited(_diagnostics.cancel());
    unawaited(transport.disconnect().catchError((Object _) {}));
    super.dispose();
  }
}
