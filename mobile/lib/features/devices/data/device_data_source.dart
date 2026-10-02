import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/widgets.dart';

import '../../../core/config/app_config.dart';
import '../domain/device.dart';

abstract interface class DeviceDataSource {
  Future<List<ConnectedDevice>> listDevices();
  Future<ConnectedDevice> getDevice(String deviceId);
  Future<List<DeviceCapability>> getCapabilities(String deviceId);
  Future<void> confirmPairing(String pairingId, String confirmationCode);
  Future<void> rejectPairing(String pairingId, String confirmationCode);
  Future<PairingChallenge> startPairing(NodeIdentity identity);
  Future<String> completePairing(PairingChallenge challenge);
  Future<void> revoke(String deviceId);
}

class NodeIdentity {
  const NodeIdentity({
    required this.displayName,
    required this.platform,
    required this.nodeVersion,
  });

  final String displayName;
  final String platform;
  final String nodeVersion;

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'platform': platform,
    'nodeVersion': nodeVersion,
  };
}

class PairingChallenge {
  const PairingChallenge({
    required this.pairingId,
    required this.pairingSecret,
    required this.confirmationCode,
    required this.identity,
    required this.expiresAt,
  });

  final String pairingId;
  final String pairingSecret;
  final String confirmationCode;
  final NodeIdentity identity;
  final DateTime expiresAt;
}

abstract interface class NodeCredentialStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

class SecureNodeCredentialStore implements NodeCredentialStore {
  SecureNodeCredentialStore({bool desktop = false})
    : _storage = desktop
          ? const FlutterSecureStorage(
              mOptions: MacOsOptions(
                accountName: AppConfig.isJointAcceptanceBuild
                    ? 'top.jxcz.orialis.jointacceptance'
                    : 'top.jxcz.orialis.desktop',
                usesDataProtectionKeychain: false,
              ),
            )
          : const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

class DeviceCenterException implements Exception {
  const DeviceCenterException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class _RequestContext {
  _RequestContext({
    required this.serverUrl,
    required this.sessionToken,
    required this.generation,
    required this.cancelToken,
  });

  final String serverUrl;
  final String? sessionToken;
  final int generation;
  final CancelToken cancelToken;

  Options get sessionOptions =>
      Options(headers: {'Authorization': 'Session $sessionToken'});

  Options get nodeOptions => Options();
}

/// Session-authenticated adapter for the contract's Node/Control v1 routes.
/// Every Node call is gated by fresh `/capabilities` discovery.
class NodeApiDeviceDataSource implements DeviceDataSource {
  NodeApiDeviceDataSource({
    AppConfig? config,
    Dio? dio,
    Dio? publicDio,
    Future<String?> Function()? sessionToken,
    Future<String> Function()? serverUrl,
    NodeCredentialStore? credentials,
  }) : _config =
           config ??
           AppConfig(desktop: defaultTargetPlatform == TargetPlatform.macOS),
       _sessionToken = sessionToken,
       _serverUrl = serverUrl,
       _credentialStorage =
           credentials ??
           SecureNodeCredentialStore(desktop: isMacOSDeviceCenter),
       _dio = dio ?? Dio(),
       _publicDio = publicDio ?? Dio() {
    _dio.options.headers.remove('X-Orialis-Device-Id');
    _publicDio.options.connectTimeout = const Duration(seconds: 4);
    _publicDio.options.receiveTimeout = const Duration(seconds: 8);
    _dio.options.connectTimeout = const Duration(seconds: 4);
    _dio.options.receiveTimeout = const Duration(seconds: 8);
    _config.addIdentityListener(_onIdentityChange);
  }

  static const capabilityName = 'multidevice.v1';
  final AppConfig _config;
  final Future<String?> Function()? _sessionToken;
  final Future<String> Function()? _serverUrl;
  final Dio _dio;
  final Dio _publicDio;
  final NodeCredentialStore _credentialStorage;
  String? _lastScopeUrl;
  String? _lastScopeToken;
  String? _accountCacheToken;
  String? _accountCacheUrl;
  String? _accountCacheId;
  final Set<CancelToken> _activeRequests = {};
  final Set<Future<void> Function()> _localNodeBindingListeners = {};
  int _identityGeneration = 0;
  bool _disposed = false;

  AppConfig get config => _config;

  void addLocalNodeBindingListener(Future<void> Function() listener) =>
      _localNodeBindingListeners.add(listener);

  void removeLocalNodeBindingListener(Future<void> Function() listener) =>
      _localNodeBindingListeners.remove(listener);

  Future<void> _notifyLocalNodeBound() async {
    for (final listener in _localNodeBindingListeners.toList()) {
      await listener();
    }
  }

  Future<_RequestContext> _captureContext() async {
    if (_disposed) throw const DeviceCenterException('设备服务已关闭');
    final generation = _identityGeneration;
    final url = (await (_serverUrl?.call() ?? _config.serverUrl()))
        .replaceFirst(RegExp(r'/+$'), '');
    if (url.isEmpty) throw const DeviceCenterException('未配置 Orialis 服务地址');
    final token = await (_sessionToken?.call() ?? _config.sessionToken());
    if (_disposed || generation != _identityGeneration) {
      throw const DeviceCenterException('账号或服务已切换，请重试');
    }
    if (token == null || token.isEmpty) {
      throw const DeviceCenterException('请先登录 Orialis 账号');
    }
    if (_lastScopeUrl != url || _lastScopeToken != token) {
      _invalidateRequests();
      _lastScopeUrl = url;
      _lastScopeToken = token;
      _identityGeneration++;
    }
    final cancelToken = CancelToken();
    _activeRequests.add(cancelToken);
    return _RequestContext(
      serverUrl: url,
      sessionToken: token,
      generation: _identityGeneration,
      cancelToken: cancelToken,
    );
  }

  Future<void> _requireProtocol(_RequestContext context) async {
    _assertCurrent(context);
    final response = await _dio.get<Map<String, dynamic>>(
      _url(context, '/api/v1/capabilities'),
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final values = response.data?['capabilities'];
    if (values is! List || values.any((value) => value is! String)) {
      throw const DeviceCenterException('服务能力响应格式无效');
    }
    if (!values.cast<String>().contains(capabilityName)) {
      throw const DeviceCenterException('此服务尚未发布多设备 Node API');
    }
  }

  void _assertCurrent(_RequestContext context) {
    if (_disposed ||
        context.generation != _identityGeneration ||
        context.cancelToken.isCancelled) {
      throw const DeviceCenterException('账号或服务已切换，请重试');
    }
  }

  Future<void> _onIdentityChange() async {
    _invalidateRequests();
    _lastScopeUrl = null;
    _lastScopeToken = null;
    _accountCacheToken = null;
    _accountCacheUrl = null;
    _accountCacheId = null;
  }

  void _invalidateRequests() {
    _identityGeneration++;
    for (final token in _activeRequests) {
      if (!token.isCancelled) token.cancel('account or server scope changed');
    }
    _activeRequests.clear();
  }

  void dispose() {
    _disposed = true;
    _invalidateRequests();
    _config.removeIdentityListener(_onIdentityChange);
    _localNodeBindingListeners.clear();
  }

  @override
  Future<List<ConnectedDevice>> listDevices() async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final accountId = await _currentAccountId(context);
    final result = <ConnectedDevice>[];
    String? cursor;
    final visitedCursors = <String>{};
    do {
      final response = await _dio.get<Map<String, dynamic>>(
        _url(context, '/api/v1/nodes'),
        queryParameters: cursor == null
            ? {'limit': 100}
            : {'cursor': cursor, 'limit': 100},
        options: context.sessionOptions,
        cancelToken: context.cancelToken,
      );
      _assertCurrent(context);
      final data = response.data;
      final nodes = data?['nodes'];
      if (data?['protocolVersion'] != '1' || nodes is! List) {
        throw const DeviceCenterException('Node 列表响应格式无效');
      }
      if (nodes.length > 100) {
        throw const DeviceCenterException('Node 列表超过协议分页上限');
      }
      for (final node in nodes) {
        if (node is! Map) throw const DeviceCenterException('Node 记录格式无效');
        final parsed = ConnectedDevice.fromJson(
          Map<String, dynamic>.from(node),
        );
        if (parsed.accountId != accountId) {
          throw const DeviceCenterException('服务返回了其他账号的设备');
        }
        result.add(parsed);
      }
      final next = data?['nextCursor'];
      if (next != null && next is! String) {
        throw const DeviceCenterException('Node 分页游标格式无效');
      }
      cursor = next as String?;
      if (cursor != null && !visitedCursors.add(cursor)) {
        throw const DeviceCenterException('Node 列表分页游标重复');
      }
    } while (cursor != null);
    return List.unmodifiable(result);
  }

  @override
  Future<ConnectedDevice> getDevice(String deviceId) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _dio.get<Map<String, dynamic>>(
      _url(context, _devicePath(deviceId)),
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final json = response.data;
    final accountId = await _currentAccountId(context);
    if (json == null ||
        json['deviceId'] != deviceId ||
        json['accountId'] != accountId) {
      throw const DeviceCenterException('设备详情与所选设备不匹配');
    }
    return ConnectedDevice.fromJson(json);
  }

  @override
  Future<List<DeviceCapability>> getCapabilities(String deviceId) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _dio.get<Map<String, dynamic>>(
      _url(context, '${_devicePath(deviceId)}/capabilities'),
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    await _currentAccountId(context);
    final data = response.data;
    if (data?['protocolVersion'] != '1' ||
        data?['deviceId'] != deviceId ||
        data?['capabilities'] is! List) {
      throw const DeviceCenterException('设备能力与所选设备不匹配');
    }
    return List.unmodifiable(
      (data!['capabilities'] as List).map((value) {
        if (value is! Map) throw const DeviceCenterException('设备能力格式无效');
        return DeviceCapability.fromJson(Map<String, dynamic>.from(value));
      }),
    );
  }

  @override
  Future<void> confirmPairing(String pairingId, String confirmationCode) =>
      _decidePairing(pairingId, confirmationCode, 'confirm');

  @override
  Future<void> rejectPairing(String pairingId, String confirmationCode) =>
      _decidePairing(pairingId, confirmationCode, 'reject');

  Future<void> _decidePairing(
    String pairingId,
    String confirmationCode,
    String decision,
  ) async {
    if (pairingId.trim().isEmpty ||
        !RegExp(r'^\d{6}$').hasMatch(confirmationCode)) {
      throw const DeviceCenterException('请输入有效的配对 ID 和 6 位确认码');
    }
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _dio.post<Map<String, dynamic>>(
      _url(
        context,
        '/api/v1/nodes/pairings/${Uri.encodeComponent(pairingId.trim())}/confirm',
      ),
      data: {'confirmationCode': confirmationCode, 'decision': decision},
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final accountId = await _currentAccountId(context);
    if (response.data?['protocolVersion'] != '1' ||
        response.data?['pairingId'] != pairingId.trim() ||
        response.data?['accountId'] != accountId ||
        response.data?['status'] !=
            (decision == 'confirm' ? 'confirmed' : 'rejected')) {
      throw const DeviceCenterException('配对决定响应与请求不匹配');
    }
  }

  @override
  Future<PairingChallenge> startPairing(NodeIdentity identity) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _publicDio.post<Map<String, dynamic>>(
      _url(context, '/api/v1/nodes/pairings'),
      data: {'protocolVersion': '1', 'nodeIdentity': identity.toJson()},
      options: context.nodeOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final data = response.data;
    final target = data?['targetNode'];
    if (data?['protocolVersion'] != '1' ||
        target is! Map ||
        data?['pairingId'] is! String ||
        data?['pairingSecret'] is! String ||
        data?['confirmationCode'] is! String ||
        data?['expiresAt'] is! String) {
      throw const DeviceCenterException('配对挑战响应格式无效');
    }
    final targetIdentity = NodeIdentity(
      displayName: target['displayName'] as String,
      platform: target['platform'] as String,
      nodeVersion: target['nodeVersion'] as String,
    );
    if (targetIdentity.displayName != identity.displayName ||
        targetIdentity.platform != identity.platform ||
        targetIdentity.nodeVersion != identity.nodeVersion) {
      throw const DeviceCenterException('配对目标身份与本机信息不匹配');
    }
    return PairingChallenge(
      pairingId: data!['pairingId'] as String,
      pairingSecret: data['pairingSecret'] as String,
      confirmationCode: data['confirmationCode'] as String,
      identity: identity,
      expiresAt: DateTime.parse(data['expiresAt'] as String),
    );
  }

  @override
  Future<String> completePairing(PairingChallenge challenge) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _publicDio.post<Map<String, dynamic>>(
      _url(
        context,
        '/api/v1/nodes/pairings/${Uri.encodeComponent(challenge.pairingId)}/complete',
      ),
      data: {
        'pairingSecret': challenge.pairingSecret,
        'nodeIdentity': challenge.identity.toJson(),
      },
      options: context.nodeOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final data = response.data;
    final deviceId = data?['deviceId'];
    final accountId = data?['accountId'];
    final credential = data?['deviceCredential'];
    if (data?['protocolVersion'] != '1' ||
        deviceId is! String ||
        deviceId.isEmpty ||
        accountId is! String ||
        accountId.isEmpty ||
        credential is! String ||
        credential.isEmpty) {
      throw const DeviceCenterException('配对完成响应格式无效');
    }
    final responseAccountId = await _currentAccountId(context);
    if (responseAccountId != accountId) {
      throw const DeviceCenterException('配对账号与当前登录账号不匹配');
    }
    _assertCurrent(context);
    final key = _nodeCredentialKey(context, deviceId, responseAccountId);
    await _credentialStorage.write(key: key, value: credential);
    try {
      _assertCurrent(context);
    } catch (_) {
      await _credentialStorage.delete(key: key);
      rethrow;
    }
    await _credentialStorage.write(
      key:
          'orialis.localNodeId.${_identityDigest(context.serverUrl, responseAccountId)}',
      value: deviceId,
    );
    _assertCurrent(context);
    await _notifyLocalNodeBound();
    return deviceId;
  }

  Future<void> heartbeat(String deviceId, String accountId) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final sessionAccountId = await _currentAccountId(context);
    if (sessionAccountId != accountId) {
      throw const DeviceCenterException('账号已切换，停止旧设备心跳');
    }
    final key = _nodeCredentialKey(context, deviceId, accountId);
    final credential = await _credentialStorage.read(key: key);
    if (credential == null || credential.isEmpty) {
      throw const DeviceCenterException('此设备没有本机 Node 凭据');
    }
    _assertCurrent(context);
    final response = await _publicDio.post<Map<String, dynamic>>(
      _url(context, '${_devicePath(deviceId)}/heartbeat'),
      data: <String, dynamic>{},
      options: Options(headers: {'Authorization': 'Node $credential'}),
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    if (response.data?['deviceId'] != deviceId) {
      throw const DeviceCenterException('心跳响应与本机设备不匹配');
    }
  }

  String _nodeCredentialKey(
    _RequestContext context,
    String deviceId,
    String accountId,
  ) =>
      'orialis.nodeCredential.${_identityDigest(context.serverUrl, '$accountId\u0000$deviceId')}';

  @override
  Future<void> revoke(String deviceId) async {
    final context = await _captureContext();
    await _requireProtocol(context);
    final response = await _dio.delete<Map<String, dynamic>>(
      _url(context, _devicePath(deviceId)),
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final accountId = await _currentAccountId(context);
    if (response.data?['protocolVersion'] != '1' ||
        response.data?['deviceId'] != deviceId ||
        response.data?['accountId'] != accountId ||
        response.data?['status'] != 'revoked') {
      throw const DeviceCenterException('服务未确认设备撤销');
    }
    await _credentialStorage.delete(
      key: _nodeCredentialKey(context, deviceId, accountId),
    );
    _assertCurrent(context);
    if ((await _localNodeBinding(context))?.$1 == deviceId) {
      await _clearLocalNodeId(context);
    }
  }

  Future<String> currentDevicePreferenceKey() async {
    final context = await _captureContext();
    final accountId = await _currentAccountId(context);
    _assertCurrent(context);
    return 'orialis.currentDeviceId.${_identityDigest(context.serverUrl, accountId)}';
  }

  Future<String?> localNodeId() async => (await localNodeBinding())?.$1;

  Future<(String, String)?> localNodeBinding() async =>
      _localNodeBinding(await _captureContext());

  Future<(String, String)?> _localNodeBinding(_RequestContext context) async {
    final accountId = await _currentAccountId(context);
    final deviceId = await _credentialStorage.read(
      key:
          'orialis.localNodeId.${_identityDigest(context.serverUrl, accountId)}',
    );
    _assertCurrent(context);
    if (deviceId == null || deviceId.isEmpty) return null;
    return (deviceId, accountId);
  }

  Future<String> currentAccountId() async =>
      _currentAccountId(await _captureContext());

  Future<String> _currentAccountId(_RequestContext context) async {
    _assertCurrent(context);
    final token = context.sessionToken!;
    if (_accountCacheToken == token &&
        _accountCacheUrl == context.serverUrl &&
        _accountCacheId != null) {
      return _accountCacheId!;
    }
    final response = await _dio.get<Map<String, dynamic>>(
      _url(context, '/api/v1/auth/session'),
      options: context.sessionOptions,
      cancelToken: context.cancelToken,
    );
    _assertCurrent(context);
    final accountId = response.data?['userId'];
    if (accountId is! String || accountId.isEmpty) {
      throw const DeviceCenterException('当前 Session 未返回账号身份');
    }
    _accountCacheToken = token;
    _accountCacheUrl = context.serverUrl;
    _accountCacheId = accountId;
    return accountId;
  }

  Future<void> clearLocalNodeId() async =>
      _clearLocalNodeId(await _captureContext());

  Future<void> _clearLocalNodeId(_RequestContext context) async {
    final accountId = await _currentAccountId(context);
    await _credentialStorage.delete(
      key:
          'orialis.localNodeId.${_identityDigest(context.serverUrl, accountId)}',
    );
    _assertCurrent(context);
  }

  Digest _identityDigest(String serverUrl, String identity) =>
      sha256.convert(utf8.encode('$serverUrl\u0000$identity'));

  String _url(_RequestContext context, String path) =>
      '${context.serverUrl}$path';

  String _devicePath(String deviceId) {
    final value = deviceId.trim();
    if (value.isEmpty ||
        value.split('/').any((part) => part == '.' || part == '..')) {
      throw const DeviceCenterException('设备 ID 无效');
    }
    return '/api/v1/nodes/${Uri.encodeComponent(value)}';
  }
}

DeviceCenterException deviceCenterException(Object error) {
  if (error is DeviceCenterException) return error;
  if (error is DioException) {
    if (error.error is DeviceCenterException) {
      return error.error! as DeviceCenterException;
    }
    final data = error.response?.data;
    final code = data is Map ? data['error'] as String? : null;
    final message = switch (code) {
      'UNAUTHENTICATED' => '登录状态已失效，请重新登录',
      'NOT_FOUND' => '设备或配对请求不存在，或不属于当前账号',
      'PAIRING_NOT_CONFIRMED' => '设备尚未确认配对',
      'PAIRING_REJECTED' => '配对请求已拒绝',
      'PAIRING_EXPIRED' => '配对请求已过期，请在目标设备重新发起',
      'PAIRING_DECISION_FINAL' => '该配对请求已作出最终决定',
      'PAIRING_ALREADY_COMPLETED' => '该配对请求已完成',
      'INVALID_ARGUMENT' => '确认码无效',
      'RATE_LIMITED' => '操作过于频繁，请稍后再试',
      _ => error.response == null ? '无法连接多设备服务' : '多设备服务暂不可用',
    };
    return DeviceCenterException(message, code: code);
  }
  return const DeviceCenterException('设备操作未完成，请重试');
}

bool get isMacOSDeviceCenter =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Renews this app's own Node lease every ten seconds while the app is active.
class NodeHeartbeatLifecycle with WidgetsBindingObserver {
  NodeHeartbeatLifecycle(this._source, {AppConfig? config})
    : _config = config ?? _source.config {
    WidgetsBinding.instance.addObserver(this);
    _config.addIdentityListener(_onIdentityChange);
    _config.addIdentityCommittedListener(identityCommitted);
    _source.addLocalNodeBindingListener(_onLocalNodeBound);
  }

  final NodeApiDeviceDataSource _source;
  final AppConfig _config;
  Timer? _timer;
  String? _deviceId;
  String? _accountId;
  int _generation = 0;
  bool _disposed = false;

  Future<void> resumeLocalNode() async {
    final generation = _generation;
    try {
      final binding = await _source.localNodeBinding();
      if (_disposed || generation != _generation || binding == null) return;
      bind(binding.$1, binding.$2);
    } catch (_) {
      if (!_disposed && generation == _generation) stop();
    }
  }

  Future<void> _onIdentityChange() async {
    stop();
  }

  Future<void> identityCommitted() => resumeLocalNode();

  Future<void> _onLocalNodeBound() => resumeLocalNode();

  void bind(String deviceId, String accountId) {
    if (_disposed || (_deviceId == deviceId && _accountId == accountId)) return;
    _deviceId = deviceId;
    _accountId = accountId;
    _generation++;
    _timer?.cancel();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startForGeneration(_generation);
    }
  }

  void stop() {
    _generation++;
    _deviceId = null;
    _accountId = null;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_deviceId != null) _startForGeneration(_generation);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startForGeneration(int generation) {
    _timer?.cancel();
    unawaited(_sendHeartbeat(generation));
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_sendHeartbeat(generation));
    });
  }

  Future<void> _sendHeartbeat(int generation) async {
    final deviceId = _deviceId;
    final accountId = _accountId;
    if (_disposed ||
        deviceId == null ||
        accountId == null ||
        generation != _generation) {
      return;
    }
    try {
      await _source.heartbeat(deviceId, accountId);
    } catch (_) {
      // The server lease expires after 30 seconds; failures never imply online.
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    _config.removeIdentityListener(_onIdentityChange);
    _config.removeIdentityCommittedListener(identityCommitted);
    _source.removeLocalNodeBindingListener(_onLocalNodeBound);
    WidgetsBinding.instance.removeObserver(this);
  }
}
