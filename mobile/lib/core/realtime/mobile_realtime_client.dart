import 'dart:async';
import 'dart:convert';

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

  Stream<MobileEnvelope> get events => _events.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_channel != null) return;
    final server = Uri.parse(await config.serverUrl());
    final uri = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/v1/ws',
      query: '',
      fragment: '',
    );
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _receive,
      onDone: () {
        _channel = null;
      },
      onError: (_, _) {
        _channel = null;
      },
    );
    _send(
      MobileEnvelope(
        type: 'hello',
        payload: {
          'device_id': await config.deviceId(),
          'platform': 'android',
          'client': 'orialis_mobile',
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
