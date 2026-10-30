import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'orialis_api_client.dart';

class UnifiedLoginCancelled implements Exception {}

class UnifiedLoginTotpRequired extends FormatException {
  const UnifiedLoginTotpRequired() : super('此账号需要动态验证码，请填写后重试');
}

class NativeLoginSession {
  const NativeLoginSession(this.session, this.username);
  final SessionResponse session;
  final String username;
}

class UnifiedLoginConsent {
  const UnifiedLoginConsent(
    this.description,
    this.scopes,
    this.claims,
    this.audience,
  );
  final String description;
  final List<String> scopes, claims, audience;
}

/// Native first-party sign-in. The server still verifies OIDC and resolves the
/// existing account; the password is sent only to the fixed identity provider.
class UnifiedLogin {
  UnifiedLogin({
    required String baseUrl,
    Dio? client,
    Dio? identityClient,
    this.timeout = const Duration(minutes: 2),
  }) : _origin = _validatedOrigin(baseUrl),
       _client = client ?? Dio(),
       _identity = identityClient ?? Dio() {
    _client.interceptors.add(CookieManager(_appCookies));
    _identity.interceptors.add(CookieManager(_identityCookies));
  }

  static const _issuer = 'https://auth.jxcz.top';
  static const _callbackPath = '/api/v1/auth/oidc/callback';
  final String _origin;
  final Dio _client;
  final Dio _identity;
  final _appCookies = CookieJar();
  final _identityCookies = CookieJar();
  final Duration timeout;
  final _cancel = CancelToken();
  Future<NativeLoginSession>? _pending;

  Future<NativeLoginSession> login({
    required String username,
    required String password,
    String? totp,
    required Future<bool> Function(UnifiedLoginConsent) onConsent,
  }) => _pending ??= _run(username.trim(), password, totp?.trim(), onConsent);

  Future<void> get stopped => _cancel.whenCancel.then((_) {});

  void cancel() => _cancel.cancel();

  Future<NativeLoginSession> _run(
    String username,
    String password,
    String? totp,
    Future<bool> Function(UnifiedLoginConsent) onConsent,
  ) async {
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      cancel();
    });
    try {
      if (username.isEmpty || password.isEmpty) {
        throw const FormatException('请输入统一账号和密码');
      }
      final start = await _request(
        _client,
        '$_origin/api/v1/auth/oidc/start',
        data: {'bind': false},
      );
      final authorization = Uri.parse(_string(_map(start.data), 'url'));
      final query = authorization.queryParametersAll;
      if (const [
        'client_id',
        'redirect_uri',
        'response_type',
        'scope',
        'state',
        'nonce',
        'code_challenge_method',
        'code_challenge',
      ].any((key) => query[key]?.length != 1)) {
        throw const FormatException('统一身份授权地址无效');
      }
      if (authorization.origin != _issuer ||
          authorization.path != '/api/oidc/authorization' ||
          authorization.userInfo.isNotEmpty ||
          authorization.hasFragment ||
          query['client_id']?.single != 'orialis-client' ||
          query['redirect_uri']?.single != '$_origin$_callbackPath' ||
          query['response_type']?.single != 'code' ||
          query['state']?.length != 1 ||
          query['state']!.single.isEmpty ||
          query['nonce']?.length != 1 ||
          query['nonce']!.single.isEmpty ||
          query['code_challenge_method']?.single != 'S256' ||
          query['code_challenge']?.length != 1 ||
          query['code_challenge']!.single.isEmpty ||
          !_allowedScopes(query['scope']?.single)) {
        throw const FormatException('统一身份授权地址无效');
      }
      final state = query['state']!.single;
      final initial = await _request(_identity, authorization.toString());
      final portal = _redirect(initial, authorization);
      final flowId = _flow(portal);
      final first = await _request(
        _identity,
        '$_issuer/api/firstfactor',
        data: {
          'username': username,
          'password': password,
          'keepMeLoggedIn': false,
          'targetURL': authorization.toString(),
          'requestMethod': 'GET',
          'flow': 'openid_connect',
          'flowID': flowId,
        },
      );
      _ok(first);
      var next = _optionalRedirect(first, authorization) ?? portal;
      var usedTotp = false;
      var completed = false;
      for (var i = 0; i < 12; i++) {
        if (next.origin == _origin && next.path == _callbackPath) {
          final params = next.queryParametersAll;
          if (params['state']?.length != 1 ||
              params['state']!.single != state ||
              params['code']?.length != 1 ||
              params['code']!.single.isEmpty ||
              params.containsKey('error') ||
              next.hasFragment ||
              next.userInfo.isNotEmpty) {
            throw const FormatException('登录回调验证失败，请重试');
          }
          final response = await _request(_client, next.toString());
          final location = _redirect(response, next);
          if (location.origin != _origin ||
              location.path != '/' ||
              location.fragment != 'oidc-complete') {
            throw const FormatException('统一账号尚未关联或登录验证失败');
          }
          completed = true;
          break;
        }
        if (next.origin != _issuer ||
            next.userInfo.isNotEmpty ||
            next.hasFragment) {
          throw const FormatException('统一登录返回了无效的地址');
        }
        if (next.path == '/api/oidc/authorization') {
          next = _redirect(await _request(_identity, next.toString()), next);
          continue;
        }
        // Portal redirects identify a JSON consent transaction. No HTML is loaded.
        final flow = _flow(next);
        final consent = await _request(
          _identity,
          '$_issuer/api/oidc/consent?flow_id=${Uri.encodeQueryComponent(flow)}',
        );
        final consentBody = _map(consent.data);
        final details = consentBody['status'] == 'OK'
            ? _map(consentBody['data'])
            : <String, dynamic>{};
        var needsFactor = details['require_login'] == true;
        // Authelia 4.39 returns HTTP 200/KO before a required second factor.
        if (consentBody['status'] != 'OK') {
          final stateResponse = await _request(_identity, '$_issuer/api/state');
          _ok(stateResponse);
          needsFactor =
              _map(_map(stateResponse.data)['data'])['authentication_level'] ==
              1;
          if (!needsFactor) {
            throw const FormatException('统一登录授权事务已失效，请重试');
          }
        }
        if (needsFactor) {
          if (usedTotp) throw const FormatException('账号要求的验证方式尚未完成');
          if (totp == null || totp.isEmpty) {
            throw const UnifiedLoginTotpRequired();
          }
          if (!RegExp(r'^\d{6,8}$').hasMatch(totp)) {
            throw const FormatException('请输入有效的动态验证码');
          }
          final factor = await _request(
            _identity,
            '$_issuer/api/secondfactor/totp',
            data: {
              'token': totp,
              'targetURL': authorization.toString(),
              'flow': 'openid_connect',
              'flowID': flow,
            },
          );
          _ok(factor);
          usedTotp = true;
          next = _optionalRedirect(factor, authorization) ?? next;
          continue;
        }
        final scopes = details['scopes'];
        if (details['client_id'] != 'orialis-client' ||
            scopes is! List ||
            !scopes.every((s) => s == 'openid' || s == 'study_identity')) {
          throw const FormatException('统一登录请求了未同意的权限');
        }
        final claims = _strings(details['claims']);
        final consentDetails = UnifiedLoginConsent(
          _string(details, 'client_description'),
          _strings(scopes),
          claims,
          _strings(details['audience']),
        );
        final allowed = await Future.any([
          onConsent(consentDetails),
          stopped.then<bool>((_) => throw UnifiedLoginCancelled()),
        ]);
        if (!allowed) throw UnifiedLoginCancelled();
        final accepted = await _request(
          _identity,
          '$_issuer/api/oidc/consent',
          data: {
            'client_id': 'orialis-client',
            'flow_id': flow,
            'consent': true,
            'pre_configure': false,
            'claims': claims,
          },
        );
        _ok(accepted);
        next = Uri.parse(
          _string(_map(_map(accepted.data)['data']), 'redirect_uri'),
        );
      }
      if (!completed) throw const FormatException('统一登录未能完成，请重试');
      final exchanged = await _request(
        _client,
        '$_origin/api/v1/auth/oidc/exchange',
        data: <String, dynamic>{},
      );
      final data = _map(exchanged.data);
      final userId = _string(data, 'userId');
      final token = _string(data, 'accessToken');
      final session = SessionResponse.fromJson(data);
      if (!session.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException('服务器返回的会话已过期，请重试');
      }
      final profile = await _request(
        _client,
        '$_origin/api/v1/auth/session',
        headers: {'Authorization': 'Session $token'},
      );
      final account = _map(profile.data);
      if (_string(account, 'userId') != userId) {
        throw const FormatException('登录账号验证失败，请重试');
      }
      if (_cancel.isCancelled) throw UnifiedLoginCancelled();
      return NativeLoginSession(session, _string(account, 'username'));
    } on DioException catch (error) {
      // Never pass a network exception containing credential request data to UI.
      if (CancelToken.isCancel(error)) {
        if (timedOut) throw const FormatException('统一登录超时，请重试');
        throw UnifiedLoginCancelled();
      }
      if (error.response?.statusCode == 429) {
        throw const FormatException('尝试过于频繁，请稍后重试');
      }
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        throw const FormatException('账号、密码或动态验证码不正确，或账号暂不可用');
      }
      throw const FormatException('统一登录暂不可用，请检查网络后重试');
    } on UnifiedLoginCancelled {
      if (timedOut) throw const FormatException('统一登录超时，请重试');
      rethrow;
    } finally {
      timer.cancel();
      _cancel.cancel();
      await _appCookies.deleteAll();
      await _identityCookies.deleteAll();
      _client.close(force: true);
      _identity.close(force: true);
    }
  }

  Future<Response<dynamic>> _request(
    Dio client,
    String url, {
    Map<String, dynamic>? data,
    Map<String, String>? headers,
  }) => client.request<dynamic>(
    url,
    data: data,
    cancelToken: _cancel,
    options: Options(
      method: data == null ? 'GET' : 'POST',
      followRedirects: false,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 400,
      headers: {'Origin': Uri.parse(url).origin, ...?headers},
    ),
  );

  static String _flow(Uri uri) {
    if (uri.origin != _issuer ||
        !const [
          '/',
          '/consent/openid/decision',
          '/2fa/one-time-password',
        ].contains(uri.path) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParametersAll['flow_id']?.length != 1 ||
        uri.queryParameters['flow'] != 'openid_connect') {
      throw const FormatException('统一登录流程无效，请重试');
    }
    return _string(uri.queryParameters, 'flow_id');
  }

  static Uri _redirect(Response<dynamic> response, Uri from) {
    final location = response.headers.value('location');
    if (response.statusCode! < 300 || location == null || location.isEmpty) {
      throw const FormatException('统一登录授权响应无效');
    }
    return from.resolve(location);
  }

  static Uri? _optionalRedirect(Response<dynamic> response, Uri from) {
    final data = _map(response.data)['data'];
    if (data is! Map || data['redirect'] == null) return null;
    return from.resolve(_string(Map<String, dynamic>.from(data), 'redirect'));
  }

  static void _ok(Response<dynamic> response) {
    if (_map(response.data)['status'] != 'OK') {
      throw const FormatException('统一身份验证未通过，请重试');
    }
  }

  static bool _allowedScopes(String? scopes) =>
      scopes != null &&
      scopes.split(' ').contains('openid') &&
      scopes.split(' ').every((s) => s == 'openid' || s == 'study_identity');

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('服务器登录响应无效，请重试');
    }
    return value;
  }

  static List<String> _strings(dynamic value) {
    if (value == null) return [];
    if (value is! List || value.any((v) => v is! String)) {
      throw const FormatException('统一登录权限响应无效');
    }
    return value.cast<String>();
  }

  static String _string(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('服务器登录响应无效，请重试');
    }
    return value;
  }

  static String _validatedOrigin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && uri.host == '127.0.0.1')) ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('服务器地址必须为 HTTPS 源站地址');
    }
    return uri.origin;
  }
}
