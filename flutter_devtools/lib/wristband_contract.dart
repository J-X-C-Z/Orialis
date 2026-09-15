import 'package:flutter/services.dart';

/// Stable, vendor-neutral contract for a future wristband provider.
enum WristbandState { disconnected, connecting, connected, unsupported, error }

WristbandState wristbandStateFromJson(Object? value) {
  switch (value) {
    case 'disconnected':
      return WristbandState.disconnected;
    case 'connecting':
      return WristbandState.connecting;
    case 'connected':
      return WristbandState.connected;
    case 'error':
      return WristbandState.error;
    default:
      return WristbandState.unsupported;
  }
}

class WristbandCapabilities {
  const WristbandCapabilities({
    required this.available,
    required this.state,
    required this.adapter,
    required this.transport,
    this.note,
    this.features = const <String, bool>{},
    this.requiresPermissions = const <String>[],
<<<<<<< HEAD
    this.raw = const <String, dynamic>{},
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  });

  factory WristbandCapabilities.fromJson(Map<String, dynamic> json) {
    final rawFeatures = json['features'];
    return WristbandCapabilities(
      available: json['available'] == true,
      state: wristbandStateFromJson(json['state']),
      adapter: json['adapter'] as String? ?? 'none',
      transport: json['transport'] as String? ?? 'none',
      note: json['note'] as String?,
      features: rawFeatures is Map
          ? rawFeatures.map((key, value) => MapEntry(key.toString(), value == true))
          : const <String, bool>{},
      requiresPermissions: (json['requiresPermissions'] as List? ?? const <Object>[])
          .whereType<String>()
          .toList(growable: false),
<<<<<<< HEAD
      raw: json,
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    );
  }

  final bool available;
  final WristbandState state;
  final String adapter;
  final String transport;
  final String? note;
  final Map<String, bool> features;
  final List<String> requiresPermissions;
<<<<<<< HEAD
  final Map<String, dynamic> raw;

  bool supports(String feature) => features[feature] == true;
  String? get nodeName => raw['nodeName'] as String?;
  String? get lastError => raw['lastError'] as String?;
  int get nodeCount => (raw['nodeCount'] as num?)?.toInt() ?? 0;
  String? get serviceConnection => raw['serviceConnection'] as String?;
=======

  bool supports(String feature) => features[feature] == true;
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}

class WristbandResult {
  const WristbandResult({required this.ok, required this.state, this.error, this.raw = const {}});

  factory WristbandResult.fromJson(Map<String, dynamic> json) => WristbandResult(
        ok: json['ok'] == true,
        state: wristbandStateFromJson(json['state']),
        error: json['error'] as String?,
        raw: json,
      );

  final bool ok;
  final WristbandState state;
  final String? error;
  final Map<String, dynamic> raw;
}

class WristbandClient {
  WristbandClient({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('app.fangcun/hyperos');

  final MethodChannel _channel;

  Future<WristbandCapabilities> capabilities() async => WristbandCapabilities.fromJson(await _call('getWristbandCapabilities'));
  Future<WristbandCapabilities> status() async => WristbandCapabilities.fromJson(await _call('getWristbandStatus'));
  Future<WristbandResult> connect([Map<String, dynamic> options = const {}]) async => WristbandResult.fromJson(await _call('connectWristband', options));
  Future<WristbandResult> disconnect() async => WristbandResult.fromJson(await _call('disconnectWristband'));
<<<<<<< HEAD
  Future<WristbandResult> openApp([Map<String, dynamic> options = const {}]) async => WristbandResult.fromJson(await _call('openWristbandApp', options));
  Future<WristbandResult> sync(Map<String, dynamic> payload) async => WristbandResult.fromJson(await _call('syncWristband', payload));
  Future<List<Map<String, dynamic>>> pollEvents() async {
    try {
      final value = await _channel.invokeMethod<dynamic>('pendingWristbandEvents');
      if (value is List) return value.whereType<Map>().map((event) => Map<String, dynamic>.from(event)).toList();
    } on MissingPluginException {
      return const <Map<String, dynamic>>[];
    }
    return const <Map<String, dynamic>>[];
  }

  Future<void> acknowledgeEvents(int count) async {
    if (count <= 0) return;
    try {
      await _channel.invokeMethod<dynamic>('acknowledgeWristbandEvents', count);
    } on MissingPluginException {
      // Older builds have no event queue; there is nothing to acknowledge.
    }
  }
=======
  Future<WristbandResult> sync(Map<String, dynamic> payload) async => WristbandResult.fromJson(await _call('syncWristband', payload));
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

  Future<Map<String, dynamic>> _call(String method, [Object? arguments]) async {
    try {
      final result = await _channel.invokeMethod<dynamic>(method, arguments);
      if (result is Map) return Map<String, dynamic>.from(result.map((key, value) => MapEntry(key.toString(), value)));
      return <String, dynamic>{'ok': false, 'state': 'unsupported', 'error': 'missing_native_module'};
    } on MissingPluginException {
      return <String, dynamic>{'ok': false, 'state': 'unsupported', 'error': 'missing_native_module'};
    }
  }
}
