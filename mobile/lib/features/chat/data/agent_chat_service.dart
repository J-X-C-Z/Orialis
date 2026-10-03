import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/config/app_config.dart';
import '../../../core/network/orialis_api_client.dart';

class ChatAgentDevice {
  const ChatAgentDevice({
    required this.id,
    required this.platform,
    required this.online,
    this.displayLabel,
  });
  final String id;
  final String platform;
  final bool online;
  final String? displayLabel;

  String get label {
    if (displayLabel != null) return displayLabel!;
    if (id == 'JXCZ_AOZORA_Hermes') return 'Azure 服务器';
    if (platform == 'macos') return 'Mac 电脑';
    return id;
  }

  factory ChatAgentDevice.fromJson(Map<String, dynamic> json) =>
      ChatAgentDevice(
        id: json['deviceId'] as String,
        platform: json['platform'] as String,
        online: json['online'] as bool,
      );
}

/// Agent chat uses the authenticated Gateway registry, separate from Node pairing.
class _PinnedSessionConfig extends AppConfig {
  _PinnedSessionConfig(this.token);
  final String token;
  @override
  Future<String?> sessionToken() async => token;
}

class AgentChatService {
  AgentChatService(
    this.config, {
    this.macDeviceId = const String.fromEnvironment(
      'ORIALIS_MAC_CHAT_DEVICE_ID',
      defaultValue: 'JXCZ_MBA_Hermes',
    ),
    this.azureDeviceId = const String.fromEnvironment(
      'ORIALIS_AZURE_CHAT_DEVICE_ID',
      defaultValue: 'JXCZ_AOZORA_Hermes',
    ),
  }) {
    config.addIdentityListener(_resetDeviceNames);
  }

  int _identityGeneration = 0;
  bool _disposed = false;
  final _targetChanges = StreamController<(String, String?)>.broadcast();
  final _refreshes = <String, Future<String?>>{};
  final _authRevisions = <(String, String), int>{};

  /// Authoritative binding changes discovered while showing cached history.
  /// An empty conversation ID invalidates all visible bindings.
  Stream<(String, String?)> get targetChanges => _targetChanges.stream;

  Future<void> _resetDeviceNames() async {
    _identityGeneration++;
    _deviceNames.clear();
    if (!_disposed) _targetChanges.add(('', null));
  }

  void dispose() {
    _disposed = true;
    _identityGeneration++;
    config.removeIdentityListener(_resetDeviceNames);
    unawaited(_targetChanges.close());
  }

  final String macDeviceId;
  final String azureDeviceId;

  bool isAllowedTarget(String? id) =>
      id != null &&
      id.isNotEmpty &&
      id.toLowerCase().endsWith('_hermes') &&
      (id == macDeviceId || id == azureDeviceId);

  final _deviceNames = <String, String>{};

  String? targetLabel(String? id) => !isAllowedTarget(id)
      ? null
      : _deviceNames[id] ?? (id == macDeviceId ? 'Mac 电脑' : 'Azure 服务器');

  String _deviceNameKey(
    (String, String) scope,
    String deviceId,
    String? username,
  ) =>
      'orialis.chatDeviceName.${sha256.convert(utf8.encode(jsonEncode([
        scope.$1,
        username == null ? ['session', scope.$2] : ['account', username],
        deviceId,
      ])))}';

  Future<void> _loadDeviceNames((String, String) scope) async {
    final username = await config.sessionUsername();
    final preferences = await SharedPreferences.getInstance();
    _deviceNames.clear();
    if (await identity() != scope) return;
    for (final id in [macDeviceId, azureDeviceId]) {
      final name = preferences.getString(_deviceNameKey(scope, id, username));
      if (name != null && name.isNotEmpty) _deviceNames[id] = name;
    }
  }

  Future<void> renameDevice(String deviceId, String name) async {
    if (!isAllowedTarget(deviceId)) throw StateError('不支持此聊天设备');
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 60) {
      throw ArgumentError('设备名称须为 1–60 个字符');
    }
    final scope = await identity();
    final username = await config.sessionUsername();
    final preferences = await SharedPreferences.getInstance();
    if (await identity() != scope) throw StateError('登录已改变，请重试');
    await preferences.setString(
      _deviceNameKey(scope, deviceId, username),
      trimmed,
    );
    if (await identity() == scope) await _loadDeviceNames(scope);
  }

  final AppConfig config;

  Future<(String, String)> identity() async {
    final token = await config.sessionToken();
    if (token == null) throw StateError('请先登录，再选择聊天设备');
    return (await config.serverUrl(), token);
  }

  Future<OrialisApiClient> client() async {
    final scope = await identity();
    return _clientFor(scope);
  }

  Future<OrialisApiClient> _clientFor((String, String) scope) async =>
      OrialisApiClient(
        baseUrl: scope.$1,
        deviceId: await config.deviceId(),
        config: _PinnedSessionConfig(scope.$2),
      );

  Future<List<ChatAgentDevice>> devices() async {
    var registry = <ChatAgentDevice>[];
    try {
      final scope = await identity();
      await _loadDeviceNames(scope);
      registry = (await (await _clientFor(
        scope,
      )).listAgentDevices()).map(ChatAgentDevice.fromJson).toList();
      if (await identity() != scope) {
        registry = [];
        _deviceNames.clear();
      }
    } on DioException {
      // Keep both device cards visible while the gateway is unreachable.
    } on StateError {
      _deviceNames.clear();
      // Signed-out users can see the two supported devices, both unavailable.
    }
    ChatAgentDevice slot(String id, String platform, String label) {
      final registered = registry.where((device) => device.id == id);
      return ChatAgentDevice(
        id: id,
        platform: platform,
        online:
            isAllowedTarget(id) &&
            registered.isNotEmpty &&
            registered.first.online,
        displayLabel: targetLabel(id) ?? label,
      );
    }

    // Use exact deployment identities; never infer a target from platform or
    // fall back to a test/Codex gateway when Hermes is unavailable.
    return [
      slot(macDeviceId, 'macos', 'Mac 电脑'),
      slot(azureDeviceId, 'linux', 'Azure 服务器'),
    ];
  }

  String _bindingCacheKey((String, String) scope, String conversationId) =>
      'orialis.hermesBinding.${sha256.convert(utf8.encode(jsonEncode([scope.$1, scope.$2, conversationId])))}';

  String _authInvalidationKey((String, String) scope) =>
      'orialis.hermesBindingInvalid.${sha256.convert(utf8.encode(jsonEncode([scope.$1, scope.$2])))}';

  Future<bool> _isCurrent((String, String) scope, int generation) async {
    if (_disposed || generation != _identityGeneration) return false;
    try {
      return await identity() == scope && generation == _identityGeneration;
    } on StateError {
      return false;
    }
  }

  /// Reads a verified, session-scoped binding without starting a request.
  Future<String?> cachedTarget(String conversationId) async {
    final generation = _identityGeneration;
    final scope = await identity();
    final preferences = await SharedPreferences.getInstance();
    await _loadDeviceNames(scope);
    if (!await _isCurrent(scope, generation) ||
        preferences.getBool(_authInvalidationKey(scope)) == true) {
      return null;
    }
    final cached = preferences.getString(
      _bindingCacheKey(scope, conversationId),
    );
    return isAllowedTarget(cached) ? cached : null;
  }

  Future<String?> target(
    String conversationId, {
    bool requireOnline = false,
  }) async {
    final generation = _identityGeneration;
    final scope = await identity();
    final preferences = await SharedPreferences.getInstance();
    final key = _bindingCacheKey(scope, conversationId);
    await _loadDeviceNames(scope);
    if (!await _isCurrent(scope, generation)) return null;
    final cached = preferences.getBool(_authInvalidationKey(scope)) == true
        ? null
        : preferences.getString(key);
    final refresh = _refreshTarget(scope, generation, conversationId, key);
    if (!requireOnline && isAllowedTarget(cached)) {
      // The API client bounds connection/response time. Repeated list renders
      // share one request, and background failures never block local history.
      unawaited(refresh.then<void>((_) {}, onError: (Object _) {}));
      return cached;
    }
    try {
      return await refresh;
    } on DioException catch (error) {
      if (requireOnline ||
          (error.response != null && (error.response!.statusCode ?? 0) < 500)) {
        rethrow;
      }
      return null;
    }
  }

  Future<String?> _refreshTarget(
    (String, String) scope,
    int generation,
    String conversationId,
    String key,
  ) {
    final requestKey = '$generation:$key';
    final authRevision = _authRevisions[scope] ?? 0;
    final existing = _refreshes[requestKey];
    if (existing != null) return existing;
    late final Future<String?> refresh;
    refresh = (() async {
      final preferences = await SharedPreferences.getInstance();
      final previous = preferences.getString(key);
      try {
        final target = await (await _clientFor(
          scope,
        )).conversationAgentDevice(conversationId);
        if (!await _isCurrent(scope, generation)) return null;
        // A concurrent authentication rejection invalidates all bindings for
        // this session, including successful requests already in flight.
        if ((_authRevisions[scope] ?? 0) != authRevision) return null;
        final allowed = isAllowedTarget(target) ? target : null;
        if (allowed != null) {
          await preferences.setString(key, allowed);
        } else {
          await preferences.remove(key);
        }
        if (!await _isCurrent(scope, generation) ||
            (_authRevisions[scope] ?? 0) != authRevision) {
          return null;
        }
        if (previous != allowed) {
          _targetChanges.add((conversationId, allowed));
        }
        return allowed;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status != null &&
            status < 500 &&
            await _isCurrent(scope, generation)) {
          if (status == 401) {
            _authRevisions[scope] = (_authRevisions[scope] ?? 0) + 1;
            await preferences.setBool(_authInvalidationKey(scope), true);
          }
          await preferences.remove(key);
          if (await _isCurrent(scope, generation)) {
            _targetChanges.add((status == 401 ? '' : conversationId, null));
          }
        }
        rethrow;
      } finally {
        if (identical(_refreshes[requestKey], refresh)) {
          _refreshes.remove(requestKey);
        }
      }
    })();
    _refreshes[requestKey] = refresh;
    return refresh;
  }

  Future<Map<String, dynamic>> createConversation(
    ChatAgentDevice device,
  ) async {
    if (!isAllowedTarget(device.id)) {
      throw StateError('仅支持已配置的 Mac 和 Azure Hermes 设备');
    }
    if (!device.online) throw StateError('设备离线，请等待连接恢复');
    final scope = await identity();
    final api = await _clientFor(scope);
    await _loadDeviceNames(scope);
    final conversation = await api.createConversation(
      title: targetLabel(device.id) ?? device.label,
    );
    try {
      await api.bindConversationAgentDevice(
        conversation['id'] as String,
        device.id,
      );
      if (await identity() != scope) {
        throw StateError('登录或服务地址已改变，请重新选择设备');
      }
    } catch (_) {
      // A server without the binding route must never expose an unbound device chat.
      try {
        await api.deleteConversation(
          conversation['id'] as String,
          (conversation['version'] as num).toInt(),
          conversation['id'] as String,
        );
      } catch (_) {
        /* Preserve the original binding error. */
      }
      rethrow;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _bindingCacheKey(scope, conversation['id'] as String),
      device.id,
    );
    return conversation;
  }
}
