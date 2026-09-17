import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';

class MobileEnvelope {
  const MobileEnvelope({
    required this.type,
    required this.payload,
    this.requestId,
    this.version = 1,
  });

  final int version;
  final String type;
  final String? requestId;
  final Map<String, dynamic> payload;

  factory MobileEnvelope.fromJson(Map<String, dynamic> json) {
    return MobileEnvelope(
      version: (json['version'] as num?)?.toInt() ?? 1,
      type: json['type'] as String? ?? 'error',
      requestId: json['request_id'] as String?,
      payload: Map<String, dynamic>.from(json['payload'] as Map? ?? const {}),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'type': type,
    if (requestId != null) 'request_id': requestId,
    'payload': payload,
  };
}

class MobileRealtimeClient {
  MobileRealtimeClient({required this.config});

  final AppConfig config;
  final _events = StreamController<MobileEnvelope>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Future<void>? _connectFuture;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  Set<String> _capabilities = const {};
  bool _capabilitiesNegotiated = false;

  Stream<MobileEnvelope> get events => _events.stream;

  bool get isConnected => _channel != null;
  bool get capabilitiesNegotiated => _capabilitiesNegotiated;
  Set<String> get capabilities => _capabilities;

  static const clientCapabilities = <String>{
    'agent.typing',
    'markdown.safe',
    'stream.delta',
    'agent.status',
    'tool.timeline',
    'clarify.card',
    'approval.card',
    'hermes.command',
    'delivery.notification',
    'session.controls',
    'artifact.created',
  };

  Future<void> connect() async {
    _disposed = false;
    if (_channel != null) return;
    _connectFuture ??= _connect();
    try {
      await _connectFuture;
    } catch (_) {
      _scheduleReconnect();
      rethrow;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connect() async {
    final server = Uri.parse(await config.serverUrl());
    final uri = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/v1/ws',
      query: '',
      fragment: '',
    );
    final token = await config.sessionToken();
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'X-Orialis-Device-Id': await config.deviceId(),
        if (token != null) 'Authorization': 'Session $token',
      },
      connectTimeout: const Duration(seconds: 4),
    );
    _channel = channel;
    _capabilities = const {};
    _capabilitiesNegotiated = false;
    _subscription = channel.stream.listen(
      _receive,
      onDone: () {
        _handleDisconnected(channel);
      },
      onError: (_, _) {
        _handleDisconnected(channel);
      },
    );
    _send(
      MobileEnvelope(
        type: 'hello',
        payload: {
          'device_id': await config.deviceId(),
          'platform': 'android',
          'client': 'orialis_mobile',
          'client_version': '0.1.0',
          'capabilities': clientCapabilities.toList()..sort(),
        },
      ),
    );
  }

  void _receive(Object? value) {
    if (value is! String) return;
    try {
      final envelope = MobileEnvelope.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
      if (envelope.type == 'hello.ack') {
        _reconnectAttempt = 0;
        final declared =
            envelope.payload['capabilities'] ?? envelope.payload['features'];
        if (declared is List) {
          _capabilities = declared.whereType<String>().toSet();
          _capabilitiesNegotiated = true;
        }
      }
      if (envelope.type == 'ping') {
        _send(
          MobileEnvelope(
            type: 'pong',
            requestId: envelope.requestId,
            payload: const {},
          ),
        );
      }
      _events.add(envelope);
    } on Object {
      _events.add(
        const MobileEnvelope(type: 'error', payload: {'code': 'invalid_json'}),
      );
    }
  }

  void _send(MobileEnvelope envelope) {
    _channel?.sink.add(jsonEncode(envelope.toJson()));
  }

  /// Sends an optional extension event through the existing mobile envelope.
  /// Older servers accept and ignore `event`, so the core message API remains
  /// fully compatible while newer servers may return a result event.
  Future<void> sendEvent({
    required String kind,
    Map<String, dynamic> payload = const {},
    String? requestId,
  }) async {
    if (_channel == null) await connect();
    _send(
      MobileEnvelope(
        type: 'event',
        requestId: requestId,
        payload: {'kind': kind, ...payload},
      ),
    );
  }

  void _handleDisconnected(WebSocketChannel channel) {
    if (!identical(_channel, channel)) return;
    _channel = null;
    _capabilitiesNegotiated = false;
    if (!_disposed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null || _connectFuture != null) return;
    final attempt = _reconnectAttempt.clamp(0, 5).toInt();
    final delaySeconds = 1 << attempt;
    _reconnectAttempt = (attempt + 1).clamp(0, 5).toInt();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      unawaited(connect().catchError((_) {}));
    });
  }

  Future<void> disconnect() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    _channel = null;
    await _subscription?.cancel();
    _subscription = null;
    await channel?.sink.close();
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}
