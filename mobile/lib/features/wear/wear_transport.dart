import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Orialis channel contract, independent of any Xiaomi package/API identity.
enum WearAvailability { available, sdkUnavailable, unsupported }

enum WearPresence { unknown, offline, online }

class WearDiagnostics {
  const WearDiagnostics({
    this.availability = WearAvailability.unsupported,
    this.serviceConnection = WearPresence.unknown,
    this.nodeCount,
    this.wearAppInstalled,
    this.permissionsGranted,
    this.nodeIds = const [],
    this.session,
    this.observedNodeId,
    this.lastError,
  });
  final WearAvailability availability;
  final WearPresence serviceConnection;
  final int? nodeCount;
  final bool? wearAppInstalled, permissionsGranted;
  final List<String> nodeIds;
  final String? session, lastError, observedNodeId;

  bool get canMessage =>
      availability == WearAvailability.available &&
      serviceConnection == WearPresence.online &&
      wearAppInstalled != false &&
      permissionsGranted == true &&
      session != null &&
      nodeIds.isNotEmpty;

  bool canMessageFor(String? node) =>
      canMessage &&
      node != null &&
      node == observedNodeId &&
      nodeIds.contains(node);

  factory WearDiagnostics.fromMap(Map<Object?, Object?> map) => WearDiagnostics(
    availability: switch (map['availability']) {
      'available' => WearAvailability.available,
      'sdk_unavailable' => WearAvailability.sdkUnavailable,
      _ => WearAvailability.unsupported,
    },
    serviceConnection: switch (map['serviceConnection']) {
      'online' => WearPresence.online,
      'offline' => WearPresence.offline,
      _ => WearPresence.unknown,
    },
    nodeCount: map['nodeCount'] as int?,
    wearAppInstalled: map['wearAppInstalled'] as bool?,
    permissionsGranted: map['permissionsGranted'] as bool?,
    nodeIds: (map['nodeIds'] as List?)?.cast<String>() ?? const [],
    session: map['session'] as String?,
    observedNodeId: map['observedNodeId'] as String?,
    lastError: map['lastError'] as String?,
  );
}

class WearMessage {
  const WearMessage(this.nodeId, this.session, this.data);
  final String nodeId, session, data;
}

abstract interface class WearTransport {
  Stream<WearMessage> get messages;
  Stream<WearDiagnostics> get diagnostics;
  Future<WearDiagnostics> connect();
  Future<WearDiagnostics> refresh();
  Future<WearDiagnostics> requestPermissions();
  Future<WearDiagnostics> selectNode(String nodeId);
  Future<void> disconnect();
  Future<void> openApp();

  /// Resolves for transport delivery only, never for Pong/persistence/business.
  Future<void> send(String nodeId, String session, String data);
}

class NativeWearTransport implements WearTransport {
  static const _methods = MethodChannel('top.jxcz.orialis/wear');
  static const _events = EventChannel('top.jxcz.orialis/wear/events');
  final bool _supported =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  late final Stream<Map<Object?, Object?>> _stream = _supported
      ? _events.receiveBroadcastStream().map(
          (value) => Map<Object?, Object?>.from(value as Map),
        )
      : const Stream.empty();

  @override
  Future<void> openApp() => _methods.invokeMethod<void>('openApp');

  @override
  Stream<WearMessage> get messages => _stream
      .where((e) => e['type'] == 'message')
      .map(
        (e) => WearMessage(
          e['nodeId'] as String,
          e['session'] as String,
          e['data'] as String,
        ),
      );
  @override
  Stream<WearDiagnostics> get diagnostics => _stream
      .where((e) => e['type'] == 'diagnostics')
      .map(
        (e) => WearDiagnostics.fromMap(
          Map<Object?, Object?>.from(e['value'] as Map),
        ),
      );
  Future<WearDiagnostics> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!_supported) return const WearDiagnostics(lastError: 'unsupported');
    try {
      return WearDiagnostics.fromMap(
        await _methods.invokeMapMethod<Object?, Object?>(method, arguments) ??
            const {},
      );
    } on MissingPluginException {
      return const WearDiagnostics(
        availability: WearAvailability.sdkUnavailable,
        lastError: 'sdk_unavailable',
      );
    }
  }

  @override
  Future<WearDiagnostics> connect() => _invoke('connect');
  @override
  Future<WearDiagnostics> refresh() => _invoke('refresh');
  @override
  Future<WearDiagnostics> requestPermissions() => _invoke('requestPermissions');
  @override
  Future<WearDiagnostics> selectNode(String nodeId) =>
      _invoke('selectNode', {'nodeId': nodeId});
  @override
  Future<void> disconnect() async {
    if (_supported) {
      try {
        await _methods.invokeMethod<void>('disconnect');
      } on MissingPluginException {
        /* No native session exists. */
      }
    }
  }

  @override
  Future<void> send(String nodeId, String session, String data) async {
    if (!_supported) throw PlatformException(code: 'unsupported');
    await _methods.invokeMethod<void>('send', {
      'nodeId': nodeId,
      'session': session,
      'data': data,
    });
  }
}
