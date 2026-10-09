import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AppConfig {
  static const isJointAcceptanceBuild = bool.fromEnvironment(
    'ORIALIS_JOINT_ACCEPTANCE',
  );
  AppConfig({this.desktop = false, this.news = false});
  final bool desktop;
  final bool news;
  final _identityListeners = <Future<void> Function()>{};
  final _identityCommittedListeners = <Future<void> Function()>{};
  void addIdentityCommittedListener(Future<void> Function() listener) =>
      _identityCommittedListeners.add(listener);
  void removeIdentityCommittedListener(Future<void> Function() listener) =>
      _identityCommittedListeners.remove(listener);
  Future<void> _identityCommitted() async {
    for (final listener in _identityCommittedListeners.toList()) {
      await listener();
    }
  }

  void addIdentityListener(Future<void> Function() listener) =>
      _identityListeners.add(listener);
  void removeIdentityListener(Future<void> Function() listener) =>
      _identityListeners.remove(listener);
  Future<void> _revokeIdentitySessions() async {
    for (final listener in _identityListeners.toList()) {
      await listener();
    }
  }

  static const _serverUrlKey = 'orialis.serverUrl';
  static const _deviceIdKey = 'orialis.deviceId';
  static const _sessionTokenKey = 'orialis.sessionToken';
  static const _sessionUsernameKey = 'orialis.sessionUsername';
  static const _legacyAuthTokenKey = 'orialis.authToken';
  static const _legacyAuthUsernameKey = 'orialis.authUsername';
  static const _compatAuthTokenKey = 'orialis.compatAuthToken';
  static const _compatAuthUsernameKey = 'orialis.compatAuthUsername';
  static const _highPerformanceModeKey = 'orialis.highPerformanceMode';
  static const _appearanceModeKey = 'orialis.appearanceMode';
  FlutterSecureStorage get _secureStorage {
    if (desktop) {
      return const FlutterSecureStorage(
        mOptions: MacOsOptions(
          accountName: isJointAcceptanceBuild
              ? 'top.jxcz.orialis.jointacceptance'
              : 'top.jxcz.orialis.desktop',
          usesDataProtectionKeychain: false,
        ),
      );
    }
    if (news) {
      return const FlutterSecureStorage(
        mOptions: MacOsOptions(
          accountName: 'top.jxcz.orialis.news',
          usesDataProtectionKeychain: false,
        ),
      );
    }
    return const FlutterSecureStorage();
  }

  /// Separate files preserve local edits and cursor/outbox state per account.
  /// Anonymous work is retained separately and never uploaded to a later login.
  Future<String> desktopDatabaseName() async {
    final server = (await serverUrl()).replaceFirst(RegExp(r'/+$'), '');
    final token = await sessionToken();
    final username = token == null ? null : await sessionUsername();
    final scope = jsonEncode([server, username]);
    return 'orialis-${desktop ? 'desktop' : 'mobile'}-${sha256.convert(utf8.encode(scope))}';
  }

  static const defaultServerUrl = String.fromEnvironment(
    'ORIALIS_SERVER_URL',
    defaultValue: 'https://orialis.jxcz.top',
  );

  Future<String> serverUrl() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_serverUrlKey) ?? defaultServerUrl;
  }

  Future<void> setServerUrl(String value) async {
    await _revokeIdentitySessions();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_serverUrlKey, value.trim());
    await _identityCommitted();
  }

  Future<bool> highPerformanceMode() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_highPerformanceModeKey) ?? true;
  }

  Future<void> setHighPerformanceMode(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_highPerformanceModeKey, value);
  }

  Future<String> appearanceMode() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_appearanceModeKey) ?? 'system';
  }

  Future<void> setAppearanceMode(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_appearanceModeKey, value);
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
    if (await sessionToken() == value) return;
    await _revokeIdentitySessions();
    // A new token must never be briefly paired with the previous account name.
    // The authenticated response commits its username separately afterward.
    final preferences = await SharedPreferences.getInstance();
    for (final key in [
      _sessionUsernameKey,
      _legacyAuthUsernameKey,
      _compatAuthUsernameKey,
    ]) {
      await preferences.remove(key);
    }
    await _secureStorage.write(key: _sessionTokenKey, value: value);
    await preferences.remove(_sessionTokenKey);
    await _identityCommitted();
  }

  Future<void> clearSessionToken() async {
    await _revokeIdentitySessions();
    await _secureStorage.delete(key: _sessionTokenKey);
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionTokenKey);
    await preferences.remove(_legacyAuthTokenKey);
    await preferences.remove(_compatAuthTokenKey);
    await _identityCommitted();
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
    final value = username.trim();
    if (await sessionUsername() == value) return;
    await _revokeIdentitySessions();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_sessionUsernameKey, value);
    await _identityCommitted();
  }

  Future<void> clearSessionUsername() async {
    if (await sessionUsername() == null) return;
    await _revokeIdentitySessions();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionUsernameKey);
    await preferences.remove(_legacyAuthUsernameKey);
    await preferences.remove(_compatAuthUsernameKey);
    await _identityCommitted();
  }
}
