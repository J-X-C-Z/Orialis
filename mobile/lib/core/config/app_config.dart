import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AppConfig {
  static const _serverUrlKey = 'orialis.serverUrl';
  static const _deviceIdKey = 'orialis.deviceId';
  static const _sessionTokenKey = 'orialis.sessionToken';
  static const _sessionUsernameKey = 'orialis.sessionUsername';
  static const _legacyAuthTokenKey = 'orialis.authToken';
  static const _legacyAuthUsernameKey = 'orialis.authUsername';
  static const _compatAuthTokenKey = 'orialis.compatAuthToken';
  static const _compatAuthUsernameKey = 'orialis.compatAuthUsername';
  static const _secureStorage = FlutterSecureStorage();
  static const defaultServerUrl = String.fromEnvironment(
    'ORIALIS_SERVER_URL',
    defaultValue: 'https://orialis.jxcz.top',
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
  /// The token is stored with platform-secure storage; the old preference key
  /// is read once only to migrate devices upgraded from the first mobile build.
  Future<String?> sessionToken() async {
    final secureToken = (await _secureStorage.read(
      key: _sessionTokenKey,
    ))?.trim();
    if (secureToken != null && secureToken.isNotEmpty) return secureToken;
    // Migrate the short-lived development storage used by the first mobile
    // builds without invalidating an existing signed-in device.
    final preferences = await SharedPreferences.getInstance();
    for (final key in [
      _sessionTokenKey,
      _legacyAuthTokenKey,
      _compatAuthTokenKey,
    ]) {
      final token = preferences.getString(key)?.trim();
      if (token != null && token.isNotEmpty) {
        await _secureStorage.write(key: _sessionTokenKey, value: token);
        await preferences.remove(key);
        return token;
      }
    }
    return null;
  }

  Future<void> setSessionToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    await _secureStorage.write(key: _sessionTokenKey, value: value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionTokenKey);
  }

  Future<void> clearSessionToken() async {
    await _secureStorage.delete(key: _sessionTokenKey);
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionTokenKey);
    await preferences.remove(_legacyAuthTokenKey);
    await preferences.remove(_compatAuthTokenKey);
  }

  Future<String?> sessionUsername() async {
    final preferences = await SharedPreferences.getInstance();
    final current = preferences.getString(_sessionUsernameKey)?.trim();
    if (current != null && current.isNotEmpty) return current;
    final legacy =
        (preferences.getString(_legacyAuthUsernameKey) ??
                preferences.getString(_compatAuthUsernameKey))
            ?.trim();
    if (legacy != null && legacy.isNotEmpty) {
      await preferences.setString(_sessionUsernameKey, legacy);
      await preferences.remove(_legacyAuthUsernameKey);
      await preferences.remove(_compatAuthUsernameKey);
      return legacy;
    }
    return null;
  }

  Future<void> setSessionUsername(String username) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_sessionUsernameKey, username.trim());
  }

  Future<void> clearSessionUsername() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionUsernameKey);
    await preferences.remove(_legacyAuthUsernameKey);
    await preferences.remove(_compatAuthUsernameKey);
  }
}
