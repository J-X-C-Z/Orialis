import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/news/news_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Config extends AppConfig {
  String server = 'https://news.example';
  String? token = 'account-a';
  @override
  Future<String> serverUrl() async => server;
  @override
  Future<String?> sessionToken() async => token;
  @override
  Future<void> clearSessionToken() async {
    token = null;
  }
}

class _Adapter implements HttpClientAdapter {
  final requests = <String>[];
  Completer<void>? gate;
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/stream')) {
      return ResponseBody.fromString('{}', 404);
    }
    requests.add(options.path);
    await gate?.future;
    return ResponseBody.fromString(
      jsonEncode({
        'data': [
          {'title': '${options.path}-${requests.length}'},
        ],
        'source': 'test',
        'stale': false,
      }),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('reopen uses persisted cache; explicit refresh still fetches', () async {
    final config = _Config();
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    await NewsRepository(config, dio: dio).get('github/daily');
    final reopened = NewsRepository(config, dio: dio);
    final results = <List<NewsLoadResult>>[];
    final sub = reopened.watch(['github/daily']).listen(results.add);
    await _until(() => results.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(results.first.single.kind, NewsLoadKind.data);
    expect(adapter.requests, hasLength(1));
    await reopened.get('github/daily');
    expect(adapter.requests, hasLength(2));
    await sub.cancel();
  });
  test('partial cache appears before missing section finishes', () async {
    final adapter = _Adapter();
    final repo = NewsRepository(
      _Config(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    await repo.get('aihot/hot');
    adapter.gate = Completer<void>();
    final results = <List<NewsLoadResult>>[];
    final sub = repo.watch(['aihot/hot', 'aihot/items']).listen(results.add);
    await _until(() => results.isNotEmpty && adapter.requests.length == 2);
    expect(results.first.map((r) => r.kind), [
      NewsLoadKind.data,
      NewsLoadKind.loading,
    ]);
    expect(adapter.requests.last, endsWith('/aihot/items'));
    adapter.gate!.complete();
    await _until(() => results.length == 2);
    expect(results.last.map((r) => r.kind), everyElement(NewsLoadKind.data));
    await sub.cancel();
  });
  test('expired cache appears before background refresh', () async {
    final adapter = _Adapter();
    final repo = NewsRepository(
      _Config(),
      dio: Dio()..httpClientAdapter = adapter,
      cacheMaxAge: Duration.zero,
    );
    await repo.get('github/weekly');
    adapter.gate = Completer<void>();
    final results = <List<NewsLoadResult>>[];
    final sub = repo.watch(['github/weekly']).listen(results.add);
    await _until(() => results.isNotEmpty && adapter.requests.length == 2);
    expect(results.first.single.payload, isNotNull);
    adapter.gate!.complete();
    await _until(() => results.length == 2);
    await sub.cancel();
  });
  test('account and server caches are isolated', () async {
    final config = _Config();
    final repo = NewsRepository(
      config,
      dio: Dio()..httpClientAdapter = _Adapter(),
    );
    await repo.get('github/daily');
    config.token = 'account-b';
    expect(
      (await repo.cached(['github/daily'])).single.kind,
      NewsLoadKind.loading,
    );
    config.token = 'account-a';
    config.server = 'https://other.example';
    expect(
      (await repo.cached(['github/daily'])).single.kind,
      NewsLoadKind.loading,
    );
    config.server = 'https://news.example';
    expect(
      (await repo.cached(['github/daily'])).single.kind,
      NewsLoadKind.data,
    );
    config.token = null;
    expect(
      (await repo.cached(['github/daily'])).single.kind,
      NewsLoadKind.needsSession,
    );
  });
  test('corrupt cache is missing rather than a false empty result', () async {
    final repo = NewsRepository(
      _Config(),
      dio: Dio()..httpClientAdapter = _Adapter(),
    );
    await repo.get('github/daily');
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    for (final bad in ['invalid json', '[]', '{}']) {
      await prefs.setString(key, bad);
      expect(
        (await repo.cached(['github/daily'])).single.kind,
        NewsLoadKind.loading,
      );
    }
  });
  test('rejected identity loses all cached sections', () async {
    final config = _Config();
    final adapter = _Adapter();
    final repo = NewsRepository(
      config,
      dio: Dio()..httpClientAdapter = adapter,
    );
    await repo.get('github/daily');
    await repo.get('aihot/hot');
    adapter.status = 401;
    expect((await repo.get('github/daily')).kind, NewsLoadKind.needsSession);
    config.token = 'account-a';
    expect(
      (await repo.cached(['github/daily', 'aihot/hot'])).map((r) => r.kind),
      everyElement(NewsLoadKind.loading),
    );
  });
  test('old pending account cannot write cache', () async {
    final config = _Config();
    final adapter = _Adapter()..gate = Completer<void>();
    final repo = NewsRepository(
      config,
      dio: Dio()..httpClientAdapter = adapter,
    );
    final pending = repo.get('github/daily');
    await _until(() => adapter.requests.isNotEmpty);
    config.token = 'account-b';
    adapter.gate!.complete();
    expect((await pending).kind, NewsLoadKind.needsSession);
    config.token = 'account-a';
    expect(
      (await repo.cached(['github/daily'])).single.kind,
      NewsLoadKind.loading,
    );
  });
}
