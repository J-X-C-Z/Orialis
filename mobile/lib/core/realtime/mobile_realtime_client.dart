import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  MobileRealtimeClient({
    required this.config,
    this.platform = 'android',
    this.clientName = 'orialis_mobile',
    this.advertisedCapabilities = clientCapabilities,
  });

  final AppConfig config;
  final String platform;
  final String clientName;
  final Set<String> advertisedCapabilities;
  final _events = StreamController<MobileEnvelope>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Future<void>? _connectFuture;
  Future<void>? _disposeFuture;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int _connectionGeneration = 0;
  bool _stopped = false;
  bool _disposed = false;
  Set<String> _capabilities = const {};
  bool _capabilitiesNegotiated = false;

  Stream<MobileEnvelope> get events => _events.stream;

  bool get isConnected => _channel != null;
  bool get capabilitiesNegotiated => _capabilitiesNegotiated;
  Set<String> get capabilities => _capabilities;

  @visibleForTesting
  bool get reconnectScheduled => _reconnectTimer != null;

  @visibleForTesting
  void ingestForTest(String value) => _receive(value);

  @visibleForTesting
  void simulateDisconnectForTest() {
    _channel = null;
    _scheduleReconnect();
  }

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
    if (_disposed) return;
    _stopped = false;
    if (_channel != null) return;
    final generation = _connectionGeneration;
    final pending = _connectFuture ??= _connect(generation);
    try {
      await pending;
    } catch (_) {
      if (!_isCurrentConnection(generation)) return;
      if (identical(_connectFuture, pending)) _connectFuture = null;
      _scheduleReconnect();
      rethrow;
    } finally {
      // A cancelled attempt must not clear a newer explicit reconnect.
      if (identical(_connectFuture, pending)) _connectFuture = null;
    }
  }

  bool _isCurrentConnection(int generation) =>
      !_disposed && !_stopped && generation == _connectionGeneration;

  Future<void> _connect(int generation) async {
    final serverUrl = await config.serverUrl();
    if (!_isCurrentConnection(generation)) return;
    final server = Uri.parse(serverUrl);
    final uri = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/v1/ws',
      query: '',
      fragment: '',
    );
    final token = await config.sessionToken();
    if (!_isCurrentConnection(generation)) return;
    final deviceId = await config.deviceId();
    if (!_isCurrentConnection(generation)) return;
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'X-Orialis-Device-Id': deviceId,
        if (token != null) 'Authorization': 'Session $token',
      },
      connectTimeout: const Duration(seconds: 4),
    );
    // IOWebSocketChannel reports handshake/DNS failures through both the
    // channel stream and its ready future. The stream listener below handles
    // reconnect state; consume ready as well so offline startup cannot surface
    // an unhandled async exception in Flutter.
    unawaited(channel.ready.catchError((_) {}));
    _channel = channel;
    _capabilities = const {};
    _capabilitiesNegotiated = false;
    _subscription = channel.stream.listen(
      (value) {
        if (_isCurrentConnection(generation) && identical(_channel, channel)) {
          _receive(value);
        }
      },
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
          'device_id': deviceId,
          'platform': platform,
          'client': clientName,
          'client_version': '0.1.0',
          'capabilities': advertisedCapabilities.toList()..sort(),
        },
      ),
    );
  }

  void _receive(Object? value) {
    if (_disposed || value is! String) return;
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
    if (_disposed || _stopped) return;
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
    if (!_disposed && !_stopped) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed ||
        _stopped ||
        _reconnectTimer != null ||
        _connectFuture != null) {
      return;
    }
    final attempt = _reconnectAttempt.clamp(0, 5).toInt();
    final delaySeconds = 1 << attempt;
    _reconnectAttempt = (attempt + 1).clamp(0, 5).toInt();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      unawaited(connect().catchError((_) {}));
    });
  }

  Future<void> disconnect() async {
    _stopped = true;
    _connectionGeneration++;
    // Invalidate pending configuration reads without waiting for them. Any
    // explicit reconnect gets its own attempt and the old one cannot open a socket.
    _connectFuture = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    _capabilities = const {};
    _capabilitiesNegotiated = false;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await disconnect();
    await _events.close();
  }
}
