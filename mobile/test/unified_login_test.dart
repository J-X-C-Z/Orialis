import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/network/unified_login.dart';
import 'package:orialis_mobile/core/network/unified_login_fields.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  const origin = 'https://orialis.jxcz.top';
  const issuer = 'https://auth.jxcz.top';
  late List<RequestOptions> requests;
  late String authorization;
  late String callbackState;
  late String callbackOrigin;
  late String returnedUserId;
  late String? authorizationOverride;
  late bool needsTotp;
  late bool factorDone;
  late bool factorKo;
  late int firstStatus;
  late String firstResult;
  late int exchangeStatus;
  late List<String> consentScopes;
  late int tokenAge;
  late Completer<ResponseBody>? stalled;

  ResponseBody json(
    Map<String, dynamic> data, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...?headers,
    },
  );
  ResponseBody redirect(String url, {bool cookie = false}) => json(
    {},
    status: 302,
    headers: {
      'location': [url],
      if (cookie)
        'set-cookie': [
          'authelia_session=idp-only; Domain=.jxcz.top; Path=/; Secure; HttpOnly',
        ],
    },
  );

  Dio client(bool identity) => Dio()
    ..httpClientAdapter = _Adapter((request) {
      requests.add(request);
      if (identity) {
        expect(request.uri.origin, issuer);
        switch (request.uri.path) {
          case '/api/oidc/authorization':
            return redirect(
              '$issuer/?flow=openid_connect&flow_id=test-flow',
              cookie: true,
            );
          case '/api/firstfactor':
            if (stalled != null) return stalled!.future;
            return json({'status': firstResult}, status: firstStatus);
          case '/api/state':
            return json({
              'status': 'OK',
              'data': {'authentication_level': 1},
            });
          case '/api/secondfactor/totp':
            factorDone = true;
            return json({'status': 'OK'});
          case '/api/oidc/consent':
            if (request.method == 'GET') {
              if (factorKo && needsTotp && !factorDone) {
                return json({'status': 'KO'});
              }
              return json({
                'status': 'OK',
                'data': {
                  'client_id': 'orialis-client',
                  'client_description': 'Orialis',
                  'scopes': consentScopes,
                  'claims': ['legacy_military_id'],
                  'audience': [],
                  'require_login': needsTotp && !factorDone,
                },
              });
            }
            return json({
              'status': 'OK',
              'data': {
                'redirect_uri':
                    '$callbackOrigin/api/v1/auth/oidc/callback?state=$callbackState&code=verified-code',
              },
            });
        }
      } else {
        expect(request.uri.origin, origin);
        // Even a parent-domain IdP cookie must never reach the application client.
        expect(
          request.headers['cookie']?.toString().contains('idp-only') ?? false,
          isFalse,
        );
        expect(
          (request.data is Map ? request.data as Map : {}).containsKey(
            'password',
          ),
          isFalse,
        );
        switch (request.uri.path) {
          case '/api/v1/auth/oidc/start':
            return json(
              {'url': authorizationOverride ?? authorization},
              headers: {
                'set-cookie': [
                  'orialis_oidc=app-only; Path=/api/v1/auth/oidc; Secure; HttpOnly',
                ],
              },
            );
          case '/api/v1/auth/oidc/callback':
            expect(
              request.headers['cookie'].toString().contains('app-only'),
              isTrue,
            );
            return redirect('$origin/#oidc-complete');
          case '/api/v1/auth/oidc/exchange':
            return json({
              'userId': 'existing-user',
              'accessToken': 'native-session',
              'expiresAt': DateTime.now()
                  .add(Duration(hours: tokenAge))
                  .toIso8601String(),
            }, status: exchangeStatus);
          case '/api/v1/auth/session':
            expect(request.headers['Authorization'], 'Session native-session');
            return json({
              'userId': returnedUserId,
              'username': 'existing-account',
            });
        }
      }
      throw StateError('Unexpected native login request path');
    });

  UnifiedLogin flow({Duration timeout = const Duration(minutes: 2)}) =>
      UnifiedLogin(
        baseUrl: origin,
        client: client(false),
        identityClient: client(true),
        timeout: timeout,
      );
  Future<NativeLoginSession> run(
    UnifiedLogin login, {
    String? totp,
    Future<bool> Function(UnifiedLoginConsent)? consent,
  }) => login.login(
    username: 'unified-user',
    password: 'test-password',
    totp: totp,
    onConsent: consent ?? (_) async => true,
  );

  setUp(() {
    requests = [];
    callbackState = 'expected-state';
    callbackOrigin = origin;
    returnedUserId = 'existing-user';
    authorizationOverride = null;
    needsTotp = false;
    factorDone = false;
    factorKo = false;
    firstStatus = 200;
    firstResult = 'OK';
    exchangeStatus = 200;
    consentScopes = ['openid', 'study_identity'];
    tokenAge = 1;
    stalled = null;
    authorization = Uri.parse('$issuer/api/oidc/authorization')
        .replace(
          queryParameters: {
            'client_id': 'orialis-client',
            'redirect_uri': '$origin/api/v1/auth/oidc/callback',
            'response_type': 'code',
            'scope': 'openid study_identity',
            'state': 'expected-state',
            'nonce': 'expected-nonce',
            'code_challenge_method': 'S256',
            'code_challenge': 'server-challenge',
          },
        )
        .toString();
  });

  test('native API login keeps the existing account, cookies and consent boundaries', () async {
    var consentCount = 0;
    final result = await run(
      flow(),
      consent: (details) async {
        consentCount++;
        expect(details.description, 'Orialis');
        expect(details.claims, ['legacy_military_id']);
        return true;
      },
    );
    expect(result.username, 'existing-account');
    expect(result.session.userId, 'existing-user');
    expect(consentCount, 1);
    final passwordRequest = requests.singleWhere(
      (r) => r.uri.path == '/api/firstfactor',
    );
    expect(passwordRequest.data['username'], 'unified-user');
    expect(passwordRequest.data['keepMeLoggedIn'], isFalse);
    expect(
      passwordRequest.headers['cookie'].toString().contains('idp-only'),
      isTrue,
    );
    expect(
      requests.any((r) => r.uri.path == '/register' || r.uri.path == '/token'),
      isFalse,
    );
    expect(
      requests.where((r) => r.uri.path == '/api/v1/auth/oidc/exchange').length,
      1,
    );
  });

  test('a password success cannot bypass required second factor', () async {
    needsTotp = true;
    await expectLater(run(flow()), throwsA(isA<UnifiedLoginTotpRequired>()));
    expect(requests.any((r) => r.uri.path.endsWith('/callback')), isFalse);
  });
  test('TOTP continues the same IdP session and consent transaction', () async {
    needsTotp = true;
    final result = await run(flow(), totp: '123456');
    expect(result.username, 'existing-account');
    expect(factorDone, isTrue);
    final factor = requests.singleWhere((r) => r.uri.path.endsWith('/totp'));
    expect(factor.data['flowID'], 'test-flow');
    expect(factor.headers['cookie'].toString().contains('idp-only'), isTrue);
  });
  test('Authelia HTTP 200 KO requires TOTP before consent', () async {
    needsTotp = true;
    factorKo = true;
    await expectLater(run(flow()), throwsA(isA<UnifiedLoginTotpRequired>()));
    expect(requests.any((r) => r.uri.path == '/api/state'), isTrue);
    requests.clear();
    final result = await run(flow(), totp: '123456');
    expect(result.username, 'existing-account');
    expect(factorDone, isTrue);
  });
  test('cancelled consent never reaches the callback or signs in', () async {
    await expectLater(
      run(flow(), consent: (_) async => false),
      throwsA(isA<UnifiedLoginCancelled>()),
    );
    expect(
      requests.any(
        (r) => r.method == 'POST' && r.uri.path == '/api/oidc/consent',
      ),
      isFalse,
    );
  });
  for (final status in [401, 403, 429, 503]) {
    test(
      'identity failure $status is sanitized and cannot produce a session',
      () async {
        firstStatus = status;
        try {
          await run(flow());
          fail('Expected authentication failure');
        } on FormatException catch (error) {
          expect(error.toString().contains('test-password'), isFalse);
        }
        expect(requests.any((r) => r.uri.path.endsWith('/exchange')), isFalse);
      },
    );
  }
  test('identity status KO cannot produce a session', () async {
    firstResult = 'KO';
    await expectLater(run(flow()), throwsFormatException);
  });
  for (final invalid in ['issuer', 'callback', 'scope', 'state', 'user']) {
    test('rejects invalid $invalid before accepting an account', () async {
      if (invalid == 'issuer') {
        authorizationOverride = authorization.replaceFirst(
          issuer,
          'https://other.test',
        );
      }
      if (invalid == 'scope') consentScopes = ['openid', 'unknown'];
      if (invalid == 'callback') callbackOrigin = 'https://other.test';
      if (invalid == 'state') callbackState = 'wrong-state';
      if (invalid == 'user') returnedUserId = 'different-user';
      await expectLater(run(flow()), throwsFormatException);
      if (invalid == 'issuer') expect(requests.length, 1);
    });
  }
  test('expired session is rejected', () async {
    tokenAge = -1;
    await expectLater(run(flow()), throwsFormatException);
  });
  test('cancel interrupts a stalled credential request', () async {
    stalled = Completer<ResponseBody>();
    final login = flow();
    final pending = run(login);
    final failure = expectLater(pending, throwsA(isA<UnifiedLoginCancelled>()));
    while (!requests.any((r) => r.uri.path == '/api/firstfactor')) {
      await Future<void>.delayed(Duration.zero);
    }
    login.cancel();
    await failure;
    stalled!.complete(json({'status': 'OK'}));
  });
  test('timeout interrupts a pending native consent dialog', () async {
    await expectLater(
      run(
        flow(timeout: const Duration(milliseconds: 40)),
        consent: (_) => Completer<bool>().future,
      ),
      throwsFormatException,
    );
  });
  test('rejects insecure or malformed server origins', () {
    for (final url in [
      'http://example.com',
      'https://user:pw@example.com',
      'https://example.com/path',
      'https://example.com/?x=1',
      'example.com',
    ]) {
      expect(() => UnifiedLogin(baseUrl: url), throwsFormatException);
    }
  });
  testWidgets('native form exposes account and obscured password fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedLoginFields(onSubmit: (_, _, _) async {}, busy: false),
        ),
      ),
    );
    expect(find.byType(UnifiedLoginFields), findsOneWidget);
    expect(find.byType(EditableText), findsNWidgets(2));
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .where((f) => f.obscureText)
          .length,
      1,
    );
    expect(find.text('使用统一账号登录'), findsOneWidget);
    expect(find.textContaining('浏览器'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
