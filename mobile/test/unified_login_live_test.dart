import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/network/unified_login.dart';

// Run only with an explicitly authorized disposable test account:
// flutter test --dart-define=ORIALIS_LIVE_SSO=true test/unified_login_live_test.dart
// This test never reads AppConfig or changes the installed app's saved account.
void main() {
  const enabled = bool.fromEnvironment('ORIALIS_LIVE_SSO');
  test(
    'live native API login and temporary Session lifecycle',
    () async {
      const origin = 'https://orialis.jxcz.top';
      final api = Dio(
        BaseOptions(
          baseUrl: origin,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          followRedirects: false,
        ),
      );
      final login = UnifiedLogin(baseUrl: origin);
      NativeLoginSession? account;
      try {
        account = await login.login(
          username: const String.fromEnvironment('ORIALIS_TEST_USERNAME'),
          password: const String.fromEnvironment('ORIALIS_TEST_PASSWORD'),
          totp: const String.fromEnvironment('ORIALIS_TEST_TOTP'),
          onConsent: (_) async => true,
        );
        expect(account.session.expiresAt.isAfter(DateTime.now()), isTrue);
        final session = await api.get<Map<String, dynamic>>(
          '/api/v1/auth/session',
          options: Options(
            headers: {
              'Authorization': 'Session ${account.session.accessToken}',
            },
          ),
        );
        // Boolean assertions avoid printing any server session response.
        expect(
          session.data?['username'] == account.username,
          isTrue,
          reason: 'Session authentication must match the unified account.',
        );
      } on DioException {
        fail('Live OAuth or Session API request failed; credentials omitted.');
      } finally {
        try {
          if (account != null) {
            await api.post<void>(
              '/api/v1/auth/logout',
              options: Options(
                headers: {
                  'Authorization': 'Session ${account.session.accessToken}',
                },
              ),
            );
          }
        } on DioException {
          fail('Temporary session logout failed; credentials omitted.');
        } finally {
          login.cancel();
          api.close(force: true);
        }
      }
    },
    skip: !enabled
        ? 'Enable ORIALIS_LIVE_SSO with an explicitly authorized test account.'
        : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
