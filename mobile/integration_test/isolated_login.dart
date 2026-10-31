import 'package:dio/dio.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';

// Historical device acceptance uses the disposable loopback server's local auth.
Future<void> isolatedLogin(
  AppConfig config,
  String username,
  String password,
) async {
  final url = await config.serverUrl();
  if (!AppConfig.isJointAcceptanceBuild || Uri.parse(url).host != '127.0.0.1') {
    throw StateError('Device acceptance requires an isolated loopback server');
  }
  final client = Dio(BaseOptions(baseUrl: url));
  try {
    final response = await client.post<Map<String, dynamic>>(
      '/api/v1/auth/login',
      data: {'username': username, 'password': password},
    );
    final session = SessionResponse.fromJson(response.data!);
    await config.setSessionToken(session.accessToken);
    await config.setSessionUsername(username);
  } finally {
    client.close();
  }
}
