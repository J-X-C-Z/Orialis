import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/app_config.dart';

final newsConfigProvider = Provider<AppConfig>((ref) => AppConfig(news: true));
final newsRepositoryProvider = Provider<NewsRepository>(
  (ref) => NewsRepository(ref.watch(newsConfigProvider)),
);

enum NewsLoadKind { data, empty, offline, error, needsSession }

class NewsPayload {
  const NewsPayload({
    required this.data,
    required this.updatedAt,
    required this.stale,
    required this.source,
    required this.error,
  });

  final dynamic data;
  final DateTime? updatedAt;
  final bool stale;
  final String source;
  final String? error;

  factory NewsPayload.fromJson(Map<String, dynamic> json) => NewsPayload(
    data: json['data'],
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    stale: json['stale'] == true,
    source: json['source']?.toString() ?? 'unknown',
    error: json['error']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'data': data,
    'updatedAt': updatedAt?.toIso8601String(),
    'stale': stale,
    'source': source,
    'error': error,
  };

  List<Map<String, dynamic>> get items {
    final value = data;
    if (value is List) {
      return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    if (value is Map) {
      final nested =
          value['items'] ??
          value['events'] ??
          value['repositories'] ??
          value['projects'];
      if (nested is List) {
        return nested.whereType<Map>().map(Map<String, dynamic>.from).toList();
      }
    }
    return const [];
  }

  Map<String, dynamic> get object => data is Map
      ? Map<String, dynamic>.from(data as Map)
      : <String, dynamic>{};
}

class NewsLoadResult {
  const NewsLoadResult(this.kind, {this.payload, this.message});
  final NewsLoadKind kind;
  final NewsPayload? payload;
  final String? message;
}

class NewsRepository {
  NewsRepository(this.config, {Dio? dio}) : _providedDio = dio;
  final AppConfig config;
  final Dio? _providedDio;
  Dio? _dio;
  String? _dioBaseUrl;
  final Set<String> _invalidatingTokens = <String>{};

  Future<Dio> _client(String baseUrl) async {
    if (_providedDio != null) {
      _providedDio.options.baseUrl = baseUrl;
      return _providedDio;
    }
    if (_dio == null || _dioBaseUrl != baseUrl) {
      _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 10),
          headers: {'Accept': 'application/json'},
        ),
      );
      _dioBaseUrl = baseUrl;
    }
    return _dio!;
  }

  Future<NewsLoadResult> get(String path, {bool requireSession = true}) async {
    final serverUrl = (await config.serverUrl()).replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final token = await config.sessionToken();
    if (requireSession && (token == null || token.isEmpty)) {
      return const NewsLoadResult(
        NewsLoadKind.needsSession,
        message: '请点击本 App 右上角账号图标登录后查看资讯。',
      );
    }
    final cacheKey = _cacheKey(path, serverUrl, token);
    try {
      final response = await (await _client(serverUrl)).get<dynamic>(
        '/api/v1/news/$path',
        options: Options(
          headers: {
            if (token != null && token.isNotEmpty)
              'Authorization': 'Session $token',
          },
        ),
      );
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      final body = response.data;
      if (body is! Map<String, dynamic> || !body.containsKey('data')) {
        throw const FormatException('新闻服务返回格式无效');
      }
      final payload = NewsPayload.fromJson(body);
      if (payload.error != null &&
          payload.items.isEmpty &&
          payload.object.isEmpty &&
          !(path == 'projects/daily' &&
              payload.source == 'orialis-project-report' &&
              payload.data is List)) {
        return NewsLoadResult(
          NewsLoadKind.error,
          payload: payload,
          message: payload.error,
        );
      }
      await _save(cacheKey, payload);
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      return NewsLoadResult(
        payload.items.isEmpty && payload.object.isEmpty
            ? NewsLoadKind.empty
            : NewsLoadKind.data,
        payload: payload,
      );
    } on DioException catch (error) {
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.remove(cacheKey);
        // A rejected session must be removed through AppConfig so identity
        // listeners revoke any completed account-scoped content and the
        // account screen can offer a fresh login form.
        if (token != null) await _clearRejectedSession(serverUrl, token);
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '登录状态已失效，请重新登录后查看。',
        );
      }
      final cached = await _read(cacheKey);
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      final isOffline = switch (error.type) {
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout => true,
        _ => false,
      };
      if (cached != null) {
        final stale = NewsPayload(
          data: cached.data,
          updatedAt: cached.updatedAt,
          stale: true,
          source: cached.source,
          error: error.message,
        );
        return NewsLoadResult(
          isOffline ? NewsLoadKind.offline : NewsLoadKind.data,
          payload: stale,
          message: error.message,
        );
      }
      return NewsLoadResult(
        isOffline ? NewsLoadKind.offline : NewsLoadKind.error,
        message: error.message ?? '请求失败，请稍后重试。',
      );
    } catch (error) {
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      final cached = await _read(cacheKey);
      if (!await _sameIdentity(serverUrl, token)) {
        return const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '账号或服务地址已更改，请刷新资讯。',
        );
      }
      if (cached != null) {
        return NewsLoadResult(
          NewsLoadKind.data,
          payload: NewsPayload(
            data: cached.data,
            updatedAt: cached.updatedAt,
            stale: true,
            source: cached.source,
            error: error.toString(),
          ),
        );
      }
      return NewsLoadResult(NewsLoadKind.error, message: error.toString());
    }
  }

  String _cacheKey(String path, String serverUrl, String? token) {
    final scope = jsonEncode([
      serverUrl,
      token == null
          ? 'anonymous'
          : sha256.convert(utf8.encode(token)).toString(),
      path,
    ]);
    return 'orialis.news.${sha256.convert(utf8.encode(scope))}';
  }

  Future<void> _clearRejectedSession(String serverUrl, String token) async {
    if (!_invalidatingTokens.add(token)) return;
    try {
      if (await _sameIdentity(serverUrl, token)) {
        await config.clearSessionToken();
      }
    } finally {
      _invalidatingTokens.remove(token);
    }
  }

  Future<bool> _sameIdentity(String serverUrl, String? token) async {
    final currentServer = (await config.serverUrl()).replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    return currentServer == serverUrl && await config.sessionToken() == token;
  }

  Future<void> _save(String key, NewsPayload payload) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, jsonEncode(payload.toJson()));
  }

  Future<NewsPayload?> _read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(key);
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic>
          ? NewsPayload.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }
}
