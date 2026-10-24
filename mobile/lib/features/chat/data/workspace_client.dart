import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/realtime/mobile_realtime_client.dart';

/// Each panel stays bound to the conversation and identity that opened it.
class WorkspaceClient {
  WorkspaceClient({
    required this.realtime,
    required this.config,
    required this.conversationId,
    this.timeout = const Duration(seconds: 20),
  }) {
    _subscription = realtime.events.listen(_receive);
    config.addIdentityListener(_invalidate);
  }

  final MobileRealtimeClient realtime;
  final AppConfig config;
  final String conversationId;
  final Duration timeout;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<MobileEnvelope> _subscription;
  bool _closed = false;

  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (_closed) throw StateError('连接已关闭，请重新打开工作区');
    final id = const Uuid().v7();
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    // Observe errors even when identity changes while sendEvent is awaiting I/O.
    final response = result.future.timeout(timeout);
    unawaited(
      response.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      unawaited(
        realtime
            .sendEvent(
              kind: 'workspace.request',
              requestId: id,
              payload: {
                ...arguments,
                'conversationId': conversationId,
                'requestId': id,
                'op': op,
              },
            )
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                if (!result.isCompleted) result.completeError(error, stack);
              },
            ),
      );
      return await response;
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(MobileEnvelope envelope) {
    if (_closed) return;
    final payload = envelope.payload;
    final id = payload['requestId'] ?? envelope.requestId;
    final waiter = _pending[id];
    if (waiter == null || waiter.isCompleted) return;
    if (envelope.type == 'error') {
      waiter.completeError(StateError(payload['message'] ?? '工作区请求失败'));
      return;
    }
    if (payload['kind'] != 'workspace.response' ||
        payload['conversationId'] != conversationId) {
      return;
    }
    if (payload['ok'] == true && payload['data'] is Map) {
      waiter.complete(Map<String, dynamic>.from(payload['data'] as Map));
    } else {
      final error = payload['error'];
      waiter.completeError(
        StateError(error is Map ? error['message'] ?? '工作区请求失败' : '工作区请求失败'),
      );
    }
  }

  Future<void> _invalidate() async {
    _closed = true;
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('登录或服务器已改变，请重新打开工作区'));
      }
    }
    _pending.clear();
  }

  void dispose() {
    config.removeIdentityListener(_invalidate);
    unawaited(_invalidate());
    unawaited(_subscription.cancel());
  }
}
