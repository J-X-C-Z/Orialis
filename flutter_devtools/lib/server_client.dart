import 'dart:convert';
import 'dart:io';

// The exception keeps a named body parameter while the base exception uses a
// positional message, which is clearer at call sites.
// ignore_for_file: use_super_parameters

typedef JsonObject = Map<String, dynamic>;

<<<<<<< HEAD
int _jsonInt(dynamic value) => value is num ? value.toInt() : 0;

JsonObject _jsonObject(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
class ServerHttpResponse {
  const ServerHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;

  JsonObject get json {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('服务器响应不是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

abstract interface class ServerTransport {
  Future<ServerHttpResponse> request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  });
}

class IoServerTransport implements ServerTransport {
  IoServerTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<ServerHttpResponse> request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.add(utf8.encode(body));
    }
    final response = await request.close();
    return ServerHttpResponse(
      response.statusCode,
      await utf8.decodeStream(response),
    );
  }
}

class FangcunApiException implements Exception {
  const FangcunApiException(this.statusCode, this.message, {this.body});

  final int statusCode;
  final String message;
  final JsonObject? body;

  @override
  String toString() => 'FangcunApiException($statusCode): $message';
}

class RevisionConflictException extends FangcunApiException {
  const RevisionConflictException({
    required this.remoteRevision,
    this.updatedAt,
    String? message,
    JsonObject? body,
  }) : super(409, message ?? '远程数据版本已变化，请重新读取后合并', body: body);

  final int remoteRevision;
  final String? updatedAt;
}

class SessionInfo {
  const SessionInfo({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    required this.user,
  });

  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final JsonObject user;
}

class DataSnapshot {
<<<<<<< HEAD
  const DataSnapshot({
    required this.data,
    required this.revision,
    this.updatedAt,
  });
=======
  const DataSnapshot({required this.data, required this.revision, this.updatedAt});
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

  final dynamic data;
  final int revision;
  final String? updatedAt;
}

class DataWriteResult {
  const DataWriteResult({required this.revision, this.updatedAt});

  final int revision;
  final String? updatedAt;
}

<<<<<<< HEAD
class LinkHealth {
  const LinkHealth({
    required this.schema,
    required this.version,
    required this.authenticated,
    required this.transport,
    required this.mode,
  });

  factory LinkHealth.fromJson(JsonObject json) => LinkHealth(
    schema: json['schema'] as String? ?? 'fangcun.link.v1',
    version: json['version'] is num ? (json['version'] as num).toInt() : 0,
    authenticated: json['authenticated'] == true,
    transport: json['transport'] as String? ?? 'not-connected',
    mode: json['mode'] as String? ?? 'pull-only',
  );

  final String schema;
  final int version;
  final bool authenticated;
  final String transport;
  final String mode;
}

class LinkSnapshot {
  const LinkSnapshot({
    required this.raw,
    required this.schema,
    required this.version,
    required this.dataState,
    required this.revision,
  });

  factory LinkSnapshot.fromJson(JsonObject json) {
    final schema = json['schema'];
    final version = json['version'];
    final dataState = json['dataState'];
    if (schema != 'fangcun.link.v1' ||
        version != 1 ||
        !const ['mock', 'live', 'stale', 'empty'].contains(dataState)) {
      throw const FormatException('手环快照协议版本不受支持');
    }
    return LinkSnapshot(
      raw: json,
      schema: schema as String,
      version: version as int,
      dataState: dataState as String,
      revision: _jsonInt((json['sync'] as Map?)?['revision']),
    );
  }

  final JsonObject raw;
  final String schema;
  final int version;
  final String dataState;
  final int revision;

  JsonObject get payload => _jsonObject(raw['payload']);
}

class FangcunServerClient {
  FangcunServerClient({required Uri baseUrl, ServerTransport? transport})
    : _baseUrl = _normaliseBaseUrl(baseUrl),
      _transport = transport ?? IoServerTransport();
=======
class FangcunServerClient {
  FangcunServerClient({
    required Uri baseUrl,
    ServerTransport? transport,
  })  : _baseUrl = _normaliseBaseUrl(baseUrl),
        _transport = transport ?? IoServerTransport();
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

  final Uri _baseUrl;
  final ServerTransport _transport;
  String? _accessToken;
<<<<<<< HEAD
  String _apiPrefix = '/api/v1';

  bool get isAuthenticated => _accessToken != null;
  String? get accessToken => _accessToken;

  void restoreSession(String accessToken) {
    _accessToken = accessToken;
  }
=======

  bool get isAuthenticated => _accessToken != null;
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

  static Uri _normaliseBaseUrl(Uri value) => value.path.endsWith('/')
      ? value.replace(path: value.path.substring(0, value.path.length - 1))
      : value;

  Uri _uri(String path) => _baseUrl.replace(path: '${_baseUrl.path}$path');

  Future<JsonObject> health() => _send('GET', '/health', authenticated: false);

<<<<<<< HEAD
  /// Public service probe used by the developer panel. Some deployments keep
  /// the v1 health route behind auth while retaining the legacy public probe.
  Future<JsonObject> publicHealth() => _sendRaw('GET', '/api/health');

  Future<SessionInfo> login(String username, String password) async {
    try {
      return await _login(username, password);
    } on FangcunApiException catch (error) {
      // schedule.woxingsf.top is currently served by the Web deployment,
      // whose user/session endpoints are still under /api. A v1 request gets
      // its generic unauthenticated response before it reaches a login route.
      if (_shouldTryLegacyAuth(error)) {
        _apiPrefix = '/api';
        return _login(username, password);
      }
      rethrow;
    }
  }

  Future<SessionInfo> _login(String username, String password) async {
    final result = await _send(
      'POST',
      '/auth/login',
      authenticated: false,
      body: {'username': username, 'password': password, 'client': 'flutter'},
    );
    final token = result['accessToken'];
    final tokenType = result['tokenType'];
    final expiresIn = result['expiresIn'];
    if (token is! String ||
        token.isEmpty ||
        tokenType != 'Session' ||
        expiresIn is! num) {
=======
  Future<SessionInfo> login(String username, String password) async {
    final result = await _send('POST', '/auth/login', authenticated: false, body: {
      'username': username,
      'password': password,
      'client': 'flutter',
    });
    final token = result['accessToken'];
    final tokenType = result['tokenType'];
    final expiresIn = result['expiresIn'];
    if (token is! String || token.isEmpty || tokenType != 'Session' || expiresIn is! num) {
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
      throw const FormatException('登录响应缺少有效的 Session 令牌信息');
    }
    _accessToken = token;
    return SessionInfo(
      accessToken: token,
      tokenType: tokenType as String,
      expiresIn: expiresIn.toInt(),
      user: _object(result['user']),
    );
  }

<<<<<<< HEAD
  Future<JsonObject> session() async {
    try {
      return await _send('GET', '/auth/session');
    } on FangcunApiException catch (error) {
      if (_shouldTryLegacyAuth(error)) {
        _apiPrefix = '/api';
        return _send('GET', '/auth/session');
      }
      rethrow;
    }
  }

  Future<DataSnapshot> getData() async {
    final result = await _sendWithRouteFallback('GET', '/data');
=======
  Future<JsonObject> session() => _send('GET', '/auth/session');

  Future<DataSnapshot> getData() async {
    final result = await _send('GET', '/data');
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    return DataSnapshot(
      data: result['data'],
      revision: _int(result['revision']),
      updatedAt: result['updatedAt'] as String?,
    );
  }

  Future<DataWriteResult> putData(dynamic data, int baseRevision) async {
<<<<<<< HEAD
    final result = await _sendWithRouteFallback(
      'PUT',
      '/data',
      body: {'data': data, 'baseRevision': baseRevision},
    );
=======
    final result = await _send('PUT', '/data', body: {
      'data': data,
      'baseRevision': baseRevision,
    });
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    return DataWriteResult(
      revision: _int(result['revision']),
      updatedAt: result['updatedAt'] as String?,
    );
  }

<<<<<<< HEAD
  Future<LinkHealth> linkHealth() async {
    try {
      return LinkHealth.fromJson(await _send('GET', '/link/health', authenticated: false));
    } on FangcunApiException catch (error) {
      if (_isMissingRoute(error)) {
        _flipApiPrefix();
        return LinkHealth.fromJson(await _send('GET', '/link/health', authenticated: false));
      }
      rethrow;
    }
  }

  Future<LinkSnapshot> getLinkSnapshot() async {
    try {
      return LinkSnapshot.fromJson(await _send('GET', '/link/snapshot'));
    } on FangcunApiException catch (error) {
      if (_isMissingRoute(error)) {
        _flipApiPrefix();
        return LinkSnapshot.fromJson(await _send('GET', '/link/snapshot'));
      }
      rethrow;
    }
  }

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  Future<void> logout() async {
    try {
      await _send('POST', '/auth/logout');
    } finally {
      _accessToken = null;
    }
  }

  Future<JsonObject> _send(
    String method,
    String path, {
    bool authenticated = true,
    JsonObject? body,
  }) async {
<<<<<<< HEAD
    return _sendRaw(method, '$_apiPrefix$path', authenticated: authenticated, body: body);
  }

  Future<JsonObject> _sendWithRouteFallback(
    String method,
    String path, {
    bool authenticated = true,
    JsonObject? body,
  }) async {
    try {
      return await _send(method, path, authenticated: authenticated, body: body);
    } on FangcunApiException catch (error) {
      if (!_isMissingRoute(error)) rethrow;
      _flipApiPrefix();
      return _send(method, path, authenticated: authenticated, body: body);
    }
  }

  Future<JsonObject> _sendRaw(
    String method,
    String path, {
    bool authenticated = false,
    JsonObject? body,
  }) async {
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (authenticated && _accessToken != null) {
      headers['Authorization'] = 'Session $_accessToken';
    }
    final response = await _transport.request(
      method,
<<<<<<< HEAD
      _uri(path),
=======
      _uri('/api/v1$path'),
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );
    JsonObject? decoded;
    try {
      decoded = response.json;
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode == 401) _accessToken = null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 409) {
        throw RevisionConflictException(
          remoteRevision: _int(decoded?['revision']),
          updatedAt: decoded?['updatedAt'] as String?,
          message: decoded?['error'] as String?,
          body: decoded,
        );
      }
      throw FangcunApiException(
        response.statusCode,
        decoded?['error'] as String? ?? '服务器请求失败',
        body: decoded,
      );
    }
    return decoded ?? (throw const FormatException('服务器响应不是 JSON 对象'));
  }

<<<<<<< HEAD
  static JsonObject _object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  bool _shouldTryLegacyAuth(FangcunApiException error) {
    if (_apiPrefix != '/api/v1') return false;
    if (error.statusCode != 401 && error.statusCode != 404) return false;
    return const {'请先登录', '接口不存在', 'Not Found'}.contains(error.message);
  }

  bool _isMissingRoute(FangcunApiException error) =>
      error.statusCode == 404 ||
      error.statusCode == 405 ||
      error.message.contains('接口不存在');

  void _flipApiPrefix() {
    _apiPrefix = _apiPrefix == '/api' ? '/api/v1' : '/api';
  }
=======
  static JsonObject _object(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : <String, dynamic>{};
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

  static int _int(dynamic value) => value is num ? value.toInt() : 0;
}
