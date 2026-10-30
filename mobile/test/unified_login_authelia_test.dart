import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/network/unified_login.dart';

class _ApplicationAdapter implements HttpClientAdapter {
  _ApplicationAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

// Real official Authelia API; only the Orialis application side is simulated.
// All TLS and URL substitutions below are confined to this opt-in test file.
void main() {
  const directory = String.fromEnvironment('ORIALIS_TEST_IDP_DIR');
  const factorMode = String.fromEnvironment('ORIALIS_TEST_TOTP_MODE');
  test(
    'real Authelia native first factor, explicit consent, PKCE and signed ID token',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final root = Directory(directory);
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates('${root.path}/certs/https.crt');
      final pinnedCertificate = File('${root.path}/certs/https.crt')
          .readAsStringSync()
          .trim();
      Dio localClient() => Dio()
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            final http = HttpClient(context: context);
            http.findProxy = (_) => 'DIRECT';
            http.badCertificateCallback = (certificate, host, port) =>
                host == '127.0.0.1' &&
                port == 19431 &&
                certificate.pem.trim() == pinnedCertificate;
            return http;
          },
        );
      const issuer = 'https://auth.jxcz.top';
      const app = 'https://orialis.jxcz.top';
      const localIssuer = 'https://127.0.0.1:19431';
      const localApp = 'https://127.0.0.1:18443';
      final verifier = base64Url
          .encode(List<int>.generate(32, (i) => i + 17))
          .replaceAll('=', '');
      const nonce = 'native-fixture-nonce';
      const state = 'native-fixture-state';
      final authorization = Uri.parse('$issuer/api/oidc/authorization')
          .replace(
            queryParameters: {
              'client_id': 'orialis-client',
              'redirect_uri': '$app/api/v1/auth/oidc/callback',
              'response_type': 'code',
              'scope': 'openid',
              'state': state,
              'nonce': nonce,
              'code_challenge_method': 'S256',
              'code_challenge': base64Url
                  .encode(sha256.convert(utf8.encode(verifier)).bytes)
                  .replaceAll('=', ''),
            },
          )
          .toString();
      String real(String value) =>
          value.replaceAll(issuer, localIssuer).replaceAll(app, localApp);
      String virtual(String value) =>
          value.replaceAll(localIssuer, issuer).replaceAll(localApp, app);
      final identity = localClient();
      final paths = <String>[];
      identity.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            paths.add(request.uri.path);
            request.path = real(request.uri.toString()).replaceAll(
              Uri.encodeQueryComponent('$app/api/v1/auth/oidc/callback'),
              Uri.encodeQueryComponent('$localApp/api/v1/auth/oidc/callback'),
            );
            request.queryParameters = {};
            request.headers['Origin'] = localIssuer;
            if (request.data is Map && request.data['targetURL'] is String) {
              request.data['targetURL'] = real(request.data['targetURL'])
                  .replaceAll(
                    Uri.encodeQueryComponent('$app/api/v1/auth/oidc/callback'),
                    Uri.encodeQueryComponent(
                      '$localApp/api/v1/auth/oidc/callback',
                    ),
                  );
            }
            handler.next(request);
          },
          onError: (error, handler) {
            // Only paths/statuses; never credential data, cookies or authorization URLs.
            stdout.writeln(
              'fixture request: path=${error.requestOptions.uri.path} status=${error.response?.statusCode} type=${error.type} cause=${error.error.runtimeType} host=${error.requestOptions.uri.host}',
            );
            handler.next(error);
          },
          onResponse: (response, handler) {
            final location = response.headers.value('location');
            if (location != null) {
              response.headers.set('location', virtual(location));
            }
            if (response.data is Map && response.data['data'] is Map) {
              for (final key in ['redirect', 'redirect_uri']) {
                final value = response.data['data'][key];
                if (value is String) {
                  response.data['data'][key] = virtual(value);
                }
              }
            }
            handler.next(response);
          },
        ),
      );
      final tokenClient = localClient();
      final scratch = await Directory.systemTemp.createTemp(
        'orialis-native-jwt-',
      );
      var signatureVerified = false;
      var consentCount = 0;
      ResponseBody json(
        Map<String, dynamic> data, {
        int status = 200,
        String? location,
      }) => ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          if (location != null) 'location': [location],
        },
      );
      final application = Dio()
        ..httpClientAdapter = _ApplicationAdapter((request) async {
          switch (request.uri.path) {
            case '/api/v1/auth/oidc/start':
              return json({'url': authorization});
            case '/api/v1/auth/oidc/callback':
              final secret = (await File(
                '${root.path}/config/test-client-secret.txt',
              ).readAsString()).trim();
              final response = await tokenClient.post<Map<String, dynamic>>(
                '$localIssuer/api/oidc/token',
                data: {
                  'grant_type': 'authorization_code',
                  'code': request.uri.queryParameters['code'],
                  'redirect_uri': '$localApp/api/v1/auth/oidc/callback',
                  'code_verifier': verifier,
                },
                options: Options(
                  contentType: Headers.formUrlEncodedContentType,
                  headers: {
                    'Authorization':
                        'Basic ${base64Encode(utf8.encode('orialis-client:$secret'))}',
                  },
                ),
              );
              final jwt = response.data!['id_token'] as String;
              final parts = jwt.split('.');
              final claims = jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              ) as Map;
              expect(claims['iss'], localIssuer);
              expect(claims['nonce'], nonce);
              expect(
                claims['aud'] is List
                    ? (claims['aud'] as List).contains('orialis-client')
                    : claims['aud'] == 'orialis-client',
                isTrue,
              );
              expect(
                (claims['exp'] as num) >
                    DateTime.now().millisecondsSinceEpoch / 1000,
                isTrue,
              );
              final public = await Process.run('openssl', [
                'pkey',
                '-in',
                '${root.path}/config/oidc-rs256.pem',
                '-pubout',
              ]);
              expect(public.exitCode, 0);
              final key = File('${scratch.path}/public.pem')
                ..writeAsStringSync(public.stdout as String);
              final signature = File('${scratch.path}/signature')
                ..writeAsBytesSync(
                  base64Url.decode(base64Url.normalize(parts[2])),
                );
              final signed = File('${scratch.path}/signed')
                ..writeAsStringSync('${parts[0]}.${parts[1]}');
              final verified = await Process.run('openssl', [
                'dgst',
                '-sha256',
                '-verify',
                key.path,
                '-signature',
                signature.path,
                signed.path,
              ]);
              expect(verified.exitCode, 0);
              signatureVerified = true;
              return json({}, status: 303, location: '$app/#oidc-complete');
            case '/api/v1/auth/oidc/exchange':
              expect(signatureVerified, isTrue);
              return json({
                'userId': 'existing-fixture-user',
                'accessToken': 'fixture-session',
                'expiresAt': DateTime.now()
                    .add(const Duration(hours: 1))
                    .toIso8601String(),
              });
            case '/api/v1/auth/session':
              return json({
                'userId': 'existing-fixture-user',
                'username': 'existing-fixture-user',
              });
            default:
              throw StateError('Unexpected simulated application endpoint');
          }
        });
      final login = UnifiedLogin(
        baseUrl: app,
        client: application,
        identityClient: identity,
      );
      try {
        final password = (await File(
          '${root.path}/config/test-user-password.txt',
        ).readAsString()).trim();
        String? totp;
        if (factorMode == 'valid') {
          final encoded = (await File(
            '${root.path}/config/test-totp-secret.txt',
          ).readAsString()).trim();
          var bits = 0;
          var count = 0;
          final secret = <int>[];
          for (final char in encoded.toUpperCase().split('')) {
            final value = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(char);
            if (value < 0) continue;
            bits = (bits << 5) | value;
            count += 5;
            if (count >= 8) {
              count -= 8;
              secret.add((bits >> count) & 255);
            }
          }
          final counter = ByteData(8)
            ..setUint64(0, DateTime.now().millisecondsSinceEpoch ~/ 30000);
          final hash = Hmac(
            sha1,
            secret,
          ).convert(counter.buffer.asUint8List()).bytes;
          final offset = hash.last & 15;
          final number =
              ((hash[offset] & 127) << 24) |
              (hash[offset + 1] << 16) |
              (hash[offset + 2] << 8) |
              hash[offset + 3];
          totp = (number % 1000000).toString().padLeft(6, '0');
        }
        if (factorMode == 'missing') {
          await expectLater(
            login.login(
              username: 'orialis-test',
              password: password,
              onConsent: (_) async => true,
            ),
            throwsA(isA<UnifiedLoginTotpRequired>()),
          );
          expect(signatureVerified, isFalse);
          return;
        }
        final account = await login.login(
          username: 'orialis-test',
          password: password,
          totp: totp,
          onConsent: (details) async {
            consentCount++;
            expect(details.scopes, ['openid']);
            return true;
          },
        );
        expect(account.username, 'existing-fixture-user');
        expect(signatureVerified, isTrue);
        expect(consentCount, 1);
        expect(paths, contains('/api/firstfactor'));
        expect(
          paths.where((p) => p == '/api/oidc/consent').length,
          factorMode == 'valid' ? 3 : 2,
        );
        expect(
          paths.any((p) => p == '/' || p == '/consent/openid/decision'),
          isFalse,
        );
      } finally {
        login.cancel();
        tokenClient.close(force: true);
        await scratch.delete(recursive: true);
        HttpOverrides.global = previousOverrides;
      }
    },
    skip: directory.isEmpty
        ? 'Requires an isolated official Authelia fixture; never uses a production account.'
        : false,
  );
}
