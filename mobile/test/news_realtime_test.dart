import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/news/news_data.dart';
import 'package:orialis_mobile/news/news_pages.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Config extends AppConfig {
  String? token = 'account-a';
  @override
  Future<String> serverUrl() async => 'https://news.example';
  @override
  Future<String?> sessionToken() async => token;
}

class _Adapter implements HttpClientAdapter {
  final events = <StreamController<Uint8List>>[];
  final connections = <RequestOptions>[];
  int snapshots = 0;
  bool unsupported = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/stream')) {
      connections.add(options);
      if (unsupported) return ResponseBody.fromString('{}', 404);
      final stream = StreamController<Uint8List>();
      events.add(stream);
      return ResponseBody(
        stream.stream,
        200,
        headers: {
          'content-type': ['text/event-stream'],
        },
      );
    }
    snapshots++;
    return ResponseBody.fromString(
      jsonEncode({
        'data': [
          {'title': 'news-$snapshots'},
        ],
        'source': 'test',
        'stale': false,
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  void emit(String channel, String revision) => events.last.add(
    Uint8List.fromList(
      utf8.encode(
        'event: news.updated\nid: $revision\ndata: ${jsonEncode({
          'channels': [channel],
          'revision': revision,
        })}\n\n',
      ),
    ),
  );
  @override
  void close({bool force = false}) {}
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _VisibleRepository extends NewsRepository {
  _VisibleRepository(super.config);
  final changes = StreamController<List<NewsLoadResult>>.broadcast();
  int starts = 0;
  int cancels = 0;
  @override
  Stream<List<NewsLoadResult>> watch(
    List<String> paths, {
    bool requireSession = true,
    Duration refreshInterval = const Duration(seconds: 30),
  }) {
    starts++;
    return changes.stream
        .transform(
          StreamTransformer<
            List<NewsLoadResult>,
            List<NewsLoadResult>
          >.fromHandlers(),
        )
        .asBroadcastStream(
          onCancel: (subscription) {
            cancels++;
            subscription.cancel();
          },
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'SSE refreshes matching channels, ignores duplicate revisions and other channels',
    () async {
      final adapter = _Adapter();
      final repo = NewsRepository(
        _Config(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final results = <List<NewsLoadResult>>[];
      final subscription = repo
          .watch(['aihot/hot', 'aihot/items'])
          .listen(results.add);
      await _until(() => results.length == 1 && adapter.events.isNotEmpty);
      expect(
        adapter.connections.single.headers['Authorization'],
        'Session account-a',
      );
      adapter.emit('github', 'r1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.snapshots, 2);
      adapter.emit('aihot', 'r2');
      await _until(() => results.length == 2);
      expect(adapter.snapshots, 4);
      adapter.emit('aihot', 'r2');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.snapshots, 4);
      await subscription.cancel();
    },
  );

  test('disconnect reconnects with Last-Event-ID', () async {
    final adapter = _Adapter();
    final repo = NewsRepository(
      _Config(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    final subscription = repo.watch(['github/daily']).listen((_) {});
    await _until(() => adapter.events.isNotEmpty);
    adapter.emit('github', 'latest-revision');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await adapter.events.last.close();
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(adapter.connections.length, 2);
    expect(
      adapter.connections.last.headers['Last-Event-ID'],
      'latest-revision',
    );
    await subscription.cancel();
  });

  test(
    'older server falls back to polling and cancellation stops requests',
    () async {
      final adapter = _Adapter()..unsupported = true;
      final repo = NewsRepository(
        _Config(),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final subscription = repo
          .watch([
            'github/weekly',
          ], refreshInterval: const Duration(milliseconds: 30))
          .listen((_) {});
      await _until(() => adapter.snapshots >= 2);
      await subscription.cancel();
      final count = adapter.snapshots;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.snapshots, count);
    },
  );

  test(
    'events from an old identity cannot refresh new account snapshots',
    () async {
      final adapter = _Adapter();
      final config = _Config();
      final repo = NewsRepository(
        config,
        dio: Dio()..httpClientAdapter = adapter,
      );
      final subscription = repo.watch(['aihot/hot']).listen((_) {});
      await _until(() => adapter.snapshots == 1 && adapter.events.isNotEmpty);
      config.token = 'account-b';
      adapter.emit('aihot', 'old-account-revision');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.snapshots, 1);
      await subscription.cancel();
    },
  );

  testWidgets('visible page updates from stream and cancels in background', (
    tester,
  ) async {
    final config = _Config();
    final repo = _VisibleRepository(config);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsConfigProvider.overrideWithValue(config),
          newsRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: Scaffold(body: AihotPage())),
      ),
    );
    List<NewsLoadResult> payload(String title) => List.generate(
      3,
      (_) => NewsLoadResult(
        NewsLoadKind.data,
        payload: NewsPayload(
          data: [
            {'title': title},
          ],
          updatedAt: null,
          stale: false,
          source: 'test',
          error: null,
        ),
      ),
    );
    repo.changes.add(payload('first publication'));
    await tester.pumpAndSettle();
    expect(find.text('first publication'), findsWidgets);
    repo.changes.add(payload('new publication'));
    await tester.pumpAndSettle();
    expect(find.text('first publication'), findsNothing);
    expect(find.text('new publication'), findsWidgets);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(repo.cancels, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(repo.starts, 2);
    await tester.pumpWidget(const SizedBox());
    await repo.changes.close();
  });
}
