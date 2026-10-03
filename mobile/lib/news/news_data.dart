import 'dart:async';
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

enum NewsLoadKind { loading, data, empty, offline, error, needsSession }

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
  NewsRepository(
    this.config, {
    Dio? dio,
    this.cacheMaxAge = const Duration(minutes: 5),
  }) : _providedDio = dio;
  final Duration cacheMaxAge;
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

  /// Refreshes published content for a mounted foreground page. Cancelling the
  /// subscription stops future requests and discards an in-flight response.
  Stream<List<NewsLoadResult>> watch(
    List<String> paths, {
    bool requireSession = true,
    Duration refreshInterval = const Duration(seconds: 30),
  }) {
    late StreamController<List<NewsLoadResult>> controller;
    Timer? timer;
    Timer? reconnect;
    CancelToken? connection;
    var cancelled = false;
    var loading = false;
    var refreshPending = false;
    var retrySeconds = 2;
    String? revision;
    final channels = paths.map((path) => path.split('/').first).toSet();
    Future<void> refresh({
      List<NewsLoadResult>? initial,
      (String, String?)? initialIdentity,
    }) async {
      if (cancelled) return;
      if (loading) {
        refreshPending = true;
        return;
      }
      loading = true;
      try {
        final server = (await config.serverUrl()).replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        final token = await config.sessionToken();
        if (initialIdentity != (server, token)) initial = null;
        final cachedResults = initial;
        final results = await Future.wait(
          paths.asMap().entries.map((entry) async {
            if (cachedResults != null && await _fresh(entry.value)) {
              return cachedResults[entry.key];
            }
            return get(entry.value, requireSession: requireSession);
          }),
        );
        if (!cancelled && await _sameIdentity(server, token)) {
          controller.add(results);
        }
      } catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      } finally {
        loading = false;
        if (refreshPending && !cancelled) {
          refreshPending = false;
          unawaited(refresh());
        }
      }
    }

    Future<void> start() async {
      try {
        final server = (await config.serverUrl()).replaceFirst(
          RegExp(r'/+$'),
          '',
        );
        final token = await config.sessionToken();
        final initial = await cached(paths, requireSession: requireSession);
        if (cancelled || !await _sameIdentity(server, token)) return;
        if (initial.any(
          (result) =>
              result.payload != null ||
              result.kind == NewsLoadKind.needsSession,
        )) {
          controller.add(initial);
        }
        final fresh = await Future.wait(paths.map(_fresh));
        if (!cancelled &&
            await _sameIdentity(server, token) &&
            !fresh.every((value) => value)) {
          await refresh(initial: initial, initialIdentity: (server, token));
        }
      } catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      }
    }

    Future<void> connect() async {
      late String server;
      String? token;
      try {
        server = (await config.serverUrl()).replaceFirst(RegExp(r'/+$'), '');
        token = await config.sessionToken();
      } catch (_) {
        // Snapshot startup reports configuration failures to the UI.
        return;
      }
      if (cancelled || (requireSession && (token == null || token.isEmpty))) {
        return;
      }
      final cancellation = CancelToken();
      connection = cancellation;
      try {
        final response = await (await _client(server)).get<ResponseBody>(
          '/api/v1/news/stream',
          cancelToken: cancellation,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: Duration.zero,
            headers: {
              'Accept': 'text/event-stream',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Session $token',
              'Last-Event-ID': ?revision,
            },
          ),
        );
        if (cancelled || !await _sameIdentity(server, token)) return;
        var event = '';
        var id = '';
        final data = <String>[];
        await for (final line
            in response.data!.stream
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (cancelled || !await _sameIdentity(server, token)) break;
          if (line.isEmpty) {
            if (event == 'news.updated' && data.isNotEmpty) {
              try {
                final body = jsonDecode(data.join('\n'));
                if (body is Map && body['channels'] is List) {
                  final nextRevision = id.isNotEmpty
                      ? id
                      : body['revision']?.toString();
                  final changed =
                      nextRevision == null || nextRevision != revision;
                  revision = nextRevision;
                  retrySeconds = 2;
                  if (changed &&
                      (body['channels'] as List).any(channels.contains)) {
                    unawaited(refresh());
                  }
                }
              } on FormatException {
                // Ignore malformed events; periodic snapshots remain available.
              }
            }
            event = '';
            id = '';
            data.clear();
          } else if (line.startsWith('event:')) {
            event = line.substring(6).trimLeft();
          } else if (line.startsWith('id:')) {
            id = line.substring(3).trimLeft();
          } else if (line.startsWith('data:')) {
            data.add(line.substring(5).trimLeft());
          }
        }
      } on DioException catch (error) {
        if (!cancelled &&
            (error.response?.statusCode == 401 ||
                error.response?.statusCode == 403)) {
          // Use the snapshot path's existing session revocation safeguards.
          unawaited(refresh());
        }
      } catch (_) {
        // Older servers and transient transport errors use polling as fallback.
      } finally {
        cancellation.cancel();
        if (!cancelled && await _sameIdentity(server, token)) {
          reconnect = Timer(
            Duration(seconds: retrySeconds),
            () => unawaited(connect()),
          );
          retrySeconds = (retrySeconds * 2).clamp(2, 30);
        }
      }
    }

    controller = StreamController<List<NewsLoadResult>>(
      onListen: () {
        unawaited(start());
        unawaited(connect());
        timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
      },
      onCancel: () {
        cancelled = true;
        timer?.cancel();
        reconnect?.cancel();
        connection?.cancel();
      },
    );
    return controller.stream;
  }

  /// Reads persisted content without a network request. Missing/corrupt entries
  /// are loading so callers can keep valid sections visible while filling gaps.
  Future<List<NewsLoadResult>> cached(
    List<String> paths, {
    bool requireSession = true,
  }) async {
    final server = (await config.serverUrl()).replaceFirst(RegExp(r'/+$'), '');
    final token = await config.sessionToken();
    if (requireSession && (token == null || token.isEmpty)) {
      return List.filled(
        paths.length,
        const NewsLoadResult(
          NewsLoadKind.needsSession,
          message: '请点击本 App 右上角账号图标登录后查看资讯。',
        ),
      );
    }
    final results = await Future.wait(
      paths.map((path) async {
        final payload = await _read(_cacheKey(path, server, token));
        return payload == null
            ? const NewsLoadResult(NewsLoadKind.loading)
            : NewsLoadResult(
                payload.items.isEmpty && payload.object.isEmpty
                    ? NewsLoadKind.empty
                    : NewsLoadKind.data,
                payload: payload,
              );
      }),
    );
    if (!await _sameIdentity(server, token)) {
      return List.filled(
        paths.length,
        const NewsLoadResult(NewsLoadKind.needsSession),
      );
    }
    return results;
  }

  Future<bool> _fresh(String path) async {
    final server = (await config.serverUrl()).replaceFirst(RegExp(r'/+$'), '');
    final token = await config.sessionToken();
    final key = _cacheKey(path, server, token);
    final preferences = await SharedPreferences.getInstance();
    try {
      final value = jsonDecode(preferences.getString(key) ?? 'null');
      if (value is! Map ||
          !value.containsKey('data') ||
          value['stale'] == true) {
        return false;
      }
      final saved = DateTime.tryParse(value['cachedAt']?.toString() ?? '');
      final age = saved == null ? null : DateTime.now().difference(saved);
      return age != null &&
          !age.isNegative &&
          age < cacheMaxAge &&
          await _sameIdentity(server, token);
    } catch (_) {
      return false;
    }
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
      await _save(cacheKey, payload, serverUrl, token);
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
      final preferences = await SharedPreferences.getInstance();
      final scope = _cacheScope(serverUrl, token);
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith('orialis.news.'),
      )) {
        try {
          final value = jsonDecode(preferences.getString(key) ?? 'null');
          if (value is Map && value['cacheScope'] == scope) {
            await preferences.remove(key);
          }
        } catch (_) {
          // Unrelated malformed entries are handled by the normal cache reader.
        }
      }
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

  String _cacheScope(String server, String? token) =>
      sha256.convert(utf8.encode(jsonEncode([server, token]))).toString();

  Future<void> _save(
    String key,
    NewsPayload payload,
    String server,
    String? token,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      key,
      jsonEncode({
        ...payload.toJson(),
        'cachedAt': DateTime.now().toUtc().toIso8601String(),
        'cacheScope': _cacheScope(server, token),
      }),
    );
  }

  Future<NewsPayload?> _read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final value = preferences.getString(key);
      if (value == null) return null;
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> && decoded.containsKey('data')
          ? NewsPayload.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }
}
