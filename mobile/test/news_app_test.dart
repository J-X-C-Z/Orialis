import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/news/news_app.dart';
import 'package:orialis_mobile/news/news_data.dart';
import 'package:orialis_mobile/news/news_pages.dart';

class _NewsRepositoryFake extends NewsRepository {
  _NewsRepositoryFake({
    AppConfig? config,
    this.dailyReport,
    this.githubBriefFails = false,
    this.articleCount = 0,
    this.aihotReports = const {},
    this.accountAware = false,
    this.accountLabel,
  }) : super(config ?? AppConfigForNewsTest());

  final requests = <(String, bool)>[];
  final Map<String, dynamic>? dailyReport;
  final bool githubBriefFails;
  final int articleCount;
  final Map<String, Map<String, dynamic>> aihotReports;
  final bool accountAware;
  final String Function()? accountLabel;

  @override
  Future<NewsLoadResult> get(String path, {bool requireSession = true}) async {
    requests.add((path, requireSession));
    if (githubBriefFails && path.startsWith('github/briefs/')) {
      return const NewsLoadResult(
        NewsLoadKind.error,
        message: 'brief generation failed',
      );
    }
    final data = switch (path) {
      'aihot/hot' => [
        {'id': 'event-1', 'title': '模型发布', 'ranking': 1, 'summary': '官方发布记录'},
      ],
      'aihot/items' => [
        for (var i = 1; i <= articleCount; i++)
          {'title': '精选 $i', 'summary': '资讯摘要 $i'},
      ],
      'aihot/events/event-1' => <String, dynamic>{
        'publicId': 'public-event-1',
        'itemId': 'internal-item-1',
        'digestUpdatedAt': '2026-10-02T00:00:00Z',
        'storyline': [
          {'time': '2026-10-02T09:00:00Z', 'content': '公开时间线内容'},
        ],
        'summary': '事件摘要',
      },
      'aihot/reports/daily' =>
        aihotReports['daily'] ?? <String, dynamic>{'title': 'AI 日报'},
      'aihot/reports/weekly' =>
        aihotReports['weekly'] ?? <String, dynamic>{'title': 'AI 周报'},
      'aihot/reports/monthly' =>
        aihotReports['monthly'] ?? <String, dynamic>{'title': 'AI 月报'},
      'github/daily' => [
        {'repository': 'owner/repo', 'ranking': 1, 'description': '基础榜单仍可用'},
      ],
      'github/weekly' => <Map<String, dynamic>>[],
      'github/briefs/daily' => <String, dynamic>{
        'title': 'GitHub 日报',
        'summary': '本期值得关注的仓库概览',
        'themes': ['Agent 工具'],
        'highlights': ['owner/repo'],
        'analysisStatus': 'complete',
        'source': 'codex',
      },
      'github/briefs/weekly' => <String, dynamic>{},
      'projects' => <Map<String, dynamic>>[],
      'projects/daily' =>
        accountAware
            ? <String, dynamic>{'summary': '报告-${accountLabel?.call() ?? ''}'}
            : dailyReport ?? <Map<String, dynamic>>[],
      _ => <String, dynamic>{},
    };
    final payload = NewsPayload(
      data: data,
      updatedAt: DateTime.utc(2026, 10, 2),
      stale: false,
      source: path == 'projects/daily'
          ? 'orialis-project-report'
          : 'test-fixture',
      error: null,
    );
    return NewsLoadResult(
      payload.items.isEmpty && payload.object.isEmpty
          ? NewsLoadKind.empty
          : NewsLoadKind.data,
      payload: payload,
    );
  }
}

class _UrlLauncherFake extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  final launches = <(String, LaunchOptions)>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url, options));
    return true;
  }
}

class _MutableNewsConfig extends AppConfig {
  _MutableNewsConfig({required this.server, required this.token})
    : super(news: true);

  String server;
  String? token;
  int clearTokenCount = 0;

  @override
  Future<String> serverUrl() async => server;

  @override
  Future<String?> sessionToken() async => token;

  @override
  Future<void> clearSessionToken() async {
    clearTokenCount++;
    token = null;
  }
}

class _BlockingNewsAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final release = Completer<void>();
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    started.complete();
    await release.future;
    return ResponseBody.fromString(
      jsonEncode({
        'data': [],
        'updatedAt': '2026-10-02T10:00:00Z',
        'stale': false,
        'source': 'test',
        'error': null,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _UnauthorizedNewsAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('unauthorized', 401);

  @override
  void close({bool force = false}) {}
}

// Avoid platform secure-storage access in the widget test. The fake repository
// never reads the config, while the app only needs the mocked theme preference.
class AppConfigForNewsTest extends AppConfig {
  AppConfigForNewsTest() : super(news: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'orialis.appearanceMode': 'light'});
  });

  testWidgets('news app uses Lumina destinations and explains empty Projects', (
    tester,
  ) async {
    final repository = _NewsRepositoryFake();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Orialis 资讯'), findsOneWidget);
    expect(find.text('模型发布'), findsOneWidget);
    expect(repository.requests, contains(('aihot/hot', true)));

    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();

    expect(find.text('尚未收到该账号的项目秘书报告'), findsOneWidget);
    expect(find.text('尚未发布今日项目总报'), findsOneWidget);
    expect(repository.requests, contains(('projects', true)));
    expect(repository.requests, contains(('projects/daily', true)));
    expect(repository.requests.every((request) => request.$2), isTrue);
  });

  testWidgets('account settings rejects invalid server URLs without saving', (
    tester,
  ) async {
    final config = _MutableNewsConfig(
      server: 'https://server-a.example',
      token: null,
    );
    final repository = _NewsRepositoryFake(config: config);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsConfigProvider.overrideWithValue(config),
          newsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('账号与服务地址'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('news-server-url')),
      'ftp://invalid.example',
    );
    await tester.tap(find.text('保存服务地址'));
    await tester.pumpAndSettle();

    expect(find.text('请输入有效的 HTTP(S) 服务地址'), findsOneWidget);
    expect(await config.serverUrl(), 'https://server-a.example');
  });

  testWidgets('Projects detail renders daily digest and raw reports', (
    tester,
  ) async {
    final repository = _NewsRepositoryFake(
      dailyReport: {
        'summary': '今日项目摘要',
        'activeProjects': 1,
        'projects': [
          {
            'project': 'Orialis',
            'completed': ['新闻客户端'],
          },
        ],
        'rawReports': [
          {
            'source': 'orialis-project-report/secretary',
            'report': {
              'project': 'Orialis',
              'completed': ['客户端联调'],
            },
          },
        ],
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();

    expect(find.text('今日项目摘要'), findsOneWidget);
    await tester.tap(find.text('查看报告'));
    await tester.pumpAndSettle();
    expect(find.text('内容摘要'), findsOneWidget);
    expect(find.text('原始秘书报告（1）'), findsOneWidget);
    expect(find.textContaining('客户端联调'), findsOneWidget);
  });

  testWidgets('GitHub baseline ranking remains visible when AI brief fails', (
    tester,
  ) async {
    final repository = _NewsRepositoryFake(githubBriefFails: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('owner/repo'), findsOneWidget);
    expect(find.text('AI 总览暂不可用，完整榜单仍可查看。'), findsOneWidget);
    expect(find.text('brief generation failed'), findsOneWidget);
    expect(repository.requests, contains(('github/daily', true)));
    expect(repository.requests, contains(('github/briefs/daily', true)));
  });

  testWidgets('GitHub page renders the published period brief', (tester) async {
    final repository = _NewsRepositoryFake();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('GitHub 日报'), findsOneWidget);
    expect(find.text('本期值得关注的仓库概览'), findsOneWidget);
    expect(find.textContaining('Agent 工具'), findsOneWidget);
    expect(find.textContaining('owner/repo'), findsWidgets);
    expect(repository.requests, contains(('github/briefs/daily', true)));
  });

  testWidgets('mobile精选 list expands without hiding content permanently', (
    tester,
  ) async {
    final repository = _NewsRepositoryFake(articleCount: 12);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('精选 1'), findsOneWidget);
    expect(find.text('精选 5'), findsOneWidget);
    expect(find.text('精选 6'), findsNothing);
    await tester.ensureVisible(find.text('展开全部 12 条精选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开全部 12 条精选'));
    await tester.pumpAndSettle();
    expect(find.text('精选 12'), findsOneWidget);

    await tester.ensureVisible(find.text('收起精选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起精选'));
    await tester.pumpAndSettle();
    expect(find.text('精选 6'), findsNothing);
  });

  testWidgets(
    'AIHOT daily, weekly and monthly reports render their API fields',
    (tester) async {
      final repository = _NewsRepositoryFake(
        aihotReports: {
          'daily': {
            'lead': {
              'title': 'Ataraxos 战胜世界冠军',
              'leadParagraph': '日报导读正文保持原样展示。',
            },
            'sections': [
              {
                'label': '模型发布/更新',
                'items': [
                  {
                    'title': '流式语音模型发布',
                    'summary': '支持 60 种语言的实时转录。',
                    'source': {'name': '官方博客'},
                    'publishedAt': '2026-10-02T08:00:00Z',
                    'links': {
                      'original': 'https://example.com/original',
                      'aihot': 'https://aihot.news/items/example',
                    },
                  },
                ],
              },
            ],
            'flashes': [
              {
                'title': 'GPT 成本下降',
                'source': {'name': 'X：AI 分析'},
                'links': {'original': 'https://example.com/flash'},
              },
            ],
            'links': {'aihot': 'https://aihot.news/daily/example'},
            'attribution': {
              'name': 'AIHOT',
              'url': 'https://aihot.news/daily/example',
            },
          },
          'weekly': {
            'headline': '本周模型价格走低',
            'overview': '周报综览完整呈现原始内容。',
            'sections': [
              {
                'label': '行业动态',
                'summary': '本周行业趋势摘要。',
                'items': [
                  {'title': '一周行业新闻', 'summary': '周报条目正文。'},
                ],
              },
            ],
          },
          'monthly': {
            'headline': '本月模型迭代密集',
            'overview': '月报综览不再显示为 Dart Map。',
            'sections': [
              {
                'label': '论文研究',
                'summary': '月度论文研究摘要。',
                'items': [
                  {'title': '重要研究成果', 'summary': '月报条目正文。'},
                ],
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [newsRepositoryProvider.overrideWithValue(repository)],
          child: const OrialisNewsApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('查看报告'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看报告'));
      await tester.pumpAndSettle();
      expect(find.text('Ataraxos 战胜世界冠军'), findsOneWidget);
      expect(find.text('日报导读正文保持原样展示。'), findsOneWidget);
      expect(find.text('模型发布/更新'), findsOneWidget);
      expect(find.text('流式语音模型发布'), findsOneWidget);
      expect(find.text('支持 60 种语言的实时转录。'), findsOneWidget);
      expect(find.text('GPT 成本下降'), findsOneWidget);
      expect(find.text('打开原文链接'), findsWidgets);
      expect(find.text('sections'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('周报'));
      await tester.tap(find.text('周报'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看报告'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看报告'));
      await tester.pumpAndSettle();
      expect(find.text('本周模型价格走低'), findsOneWidget);
      expect(find.text('周报综览完整呈现原始内容。'), findsOneWidget);
      expect(find.text('本周行业趋势摘要。'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('月报'));
      await tester.tap(find.text('月报'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看报告'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看报告'));
      await tester.pumpAndSettle();
      expect(find.text('本月模型迭代密集'), findsOneWidget);
      expect(find.text('月报综览不再显示为 Dart Map。'), findsOneWidget);
      expect(find.text('月度论文研究摘要。'), findsOneWidget);
    },
  );

  testWidgets('AIHOT event hides internal identifiers but keeps its timeline', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsRepositoryProvider.overrideWithValue(_NewsRepositoryFake()),
        ],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('模型发布'));
    await tester.pumpAndSettle();

    expect(find.text('事件摘要'), findsWidgets);
    expect(find.text('公开时间线内容'), findsOneWidget);
    expect(find.text('public-event-1'), findsNothing);
    expect(find.text('internal-item-1'), findsNothing);
    expect(find.text('digestUpdatedAt'), findsNothing);
    expect(find.text('storyline'), findsNothing);
  });

  testWidgets('completed account-scoped content clears and reloads on switch', (
    tester,
  ) async {
    final config = _MutableNewsConfig(
      server: 'https://server-a.example',
      token: 'token-a',
    );
    final repository = _NewsRepositoryFake(
      config: config,
      accountAware: true,
      accountLabel: () => config.token ?? '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          newsConfigProvider.overrideWithValue(config),
          newsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const OrialisNewsApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    expect(find.text('报告-token-a'), findsOneWidget);

    config.server = 'https://server-b.example';
    config.token = 'token-b';
    final identityChange = config.setServerUrl(config.server);
    await tester.pump();
    expect(find.text('报告-token-a'), findsNothing);
    await identityChange;
    await tester.pumpAndSettle();
    expect(find.text('报告-token-b'), findsOneWidget);
  });

  test(
    'news envelope decoder retains stale/source/error metadata and list rows',
    () {
      final payload = NewsPayload.fromJson({
        'data': [
          {'repository': 'owner/repo', 'starsInPeriod': 42},
        ],
        'updatedAt': '2026-10-02T10:00:00Z',
        'stale': true,
        'source': 'github.com/trending',
        'error': 'upstream timeout',
      });

      expect(payload.items.single['repository'], 'owner/repo');
      expect(payload.items.single['starsInPeriod'], 42);
      expect(payload.stale, isTrue);
      expect(payload.source, 'github.com/trending');
      expect(payload.error, 'upstream timeout');
    },
  );

  test('news link launcher allows HTTP(S) and opens externally', () async {
    final launcher = _UrlLauncherFake();
    final previousLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

    expect(await launchNewsLink('https://example.com/article'), isTrue);
    expect(
      launcher.launches.last.$2.mode,
      PreferredLaunchMode.externalApplication,
    );
    expect(await launchNewsLink('http://example.com/source'), isTrue);
    expect(await launchNewsLink('javascript:alert(1)'), isFalse);
    expect(await launchNewsLink('//example.com/path'), isFalse);
    expect(launcher.launches.map((launch) => launch.$1), [
      'https://example.com/article',
      'http://example.com/source',
    ]);
  });

  test('pending news request cannot cross an account switch', () async {
    final config = _MutableNewsConfig(
      server: 'https://server-a.example',
      token: 'token-a',
    );
    final adapter = _BlockingNewsAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final request = NewsRepository(config, dio: dio).get('projects');
    await adapter.started.future;

    expect(adapter.request!.uri.host, 'server-a.example');
    expect(adapter.request!.headers['Authorization'], 'Session token-a');
    config.token = 'token-b';
    adapter.release.complete();

    final result = await request;
    expect(result.kind, NewsLoadKind.needsSession);
    expect(result.payload, isNull);
    expect(
      (await SharedPreferences.getInstance()).getKeys().where(
        (key) => key.startsWith('orialis.news.'),
      ),
      isEmpty,
    );
  });

  test('pending news request cannot cross a server switch', () async {
    final config = _MutableNewsConfig(
      server: 'https://server-a.example',
      token: 'token-a',
    );
    final adapter = _BlockingNewsAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final request = NewsRepository(config, dio: dio).get('projects');
    await adapter.started.future;

    expect(adapter.request!.uri.host, 'server-a.example');
    expect(adapter.request!.headers['Authorization'], 'Session token-a');
    config.server = 'https://server-b.example';
    adapter.release.complete();

    final result = await request;
    expect(result.kind, NewsLoadKind.needsSession);
    expect(result.payload, isNull);
    expect(
      (await SharedPreferences.getInstance()).getKeys().where(
        (key) => key.startsWith('orialis.news.'),
      ),
      isEmpty,
    );
  });

  test('an expired session is cleared so the user can sign in again', () async {
    final config = _MutableNewsConfig(
      server: 'https://server-a.example',
      token: 'expired-token',
    );
    final dio = Dio()..httpClientAdapter = _UnauthorizedNewsAdapter();

    final repository = NewsRepository(config, dio: dio);
    final results = await Future.wait([
      repository.get('projects'),
      repository.get('projects/daily'),
    ]);

    expect(
      results.map((result) => result.kind),
      everyElement(NewsLoadKind.needsSession),
    );
    expect(results.first.message, '登录状态已失效，请重新登录后查看。');
    expect(config.token, isNull);
    expect(config.clearTokenCount, 1);
  });

  test('event uses available reports and derives source links', () {
    final data = {
      'storyline': <dynamic>[],
      'reports': [
        {
          'time': '2026-10-02T09:00:00Z',
          'content': '官方说明已发布',
          'source': 'Example News',
          'links': {'original': 'https://example.com/report'},
        },
      ],
    };

    expect(newsEventTimeline(data), same(data['reports']));
    expect(newsEventSources(data), [
      {'name': 'Example News', 'url': 'https://example.com/report'},
    ]);
  });
}
