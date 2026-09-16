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
    if (_channel != null) return;
    _connectFuture ??= _connect();
    try {
      await _connectFuture;
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
        _channel = null;
        _capabilitiesNegotiated = false;
      },
      onError: (_, _) {
        _channel = null;
        _capabilitiesNegotiated = false;
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

  Future<void> disconnect() async {
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
