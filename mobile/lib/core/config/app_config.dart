import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AppConfig {
  static const _serverUrlKey = 'orialis.serverUrl';
  static const _deviceIdKey = 'orialis.deviceId';
  static const _sessionTokenKey = 'orialis.sessionToken';
  static const defaultServerUrl = String.fromEnvironment(
    'ORIALIS_SERVER_URL',
    defaultValue: 'http://127.0.0.1:18443',
  );

  Future<String> serverUrl() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_serverUrlKey) ?? defaultServerUrl;
  }

  Future<void> setServerUrl(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_serverUrlKey, value.trim());
  }

  Future<String> deviceId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final value = const Uuid().v7();
    await preferences.setString(_deviceIdKey, value);
    return value;
  }

  /// Returns the persisted opaque Session token, if the user is signed in.
  ///
  /// SharedPreferences is kept behind this interface so the storage can be
  /// replaced by platform-secure storage without changing API consumers.
  Future<String?> sessionToken() async {
    final preferences = await SharedPreferences.getInstance();
    final token = preferences.getString(_sessionTokenKey)?.trim();
    return token == null || token.isEmpty ? null : token;
  }

  Future<void> setSessionToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_sessionTokenKey, value);
  }

  Future<void> clearSessionToken() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionTokenKey);
  }
}
