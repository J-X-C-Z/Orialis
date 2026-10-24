import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';
import 'package:orialis_mobile/features/memory/domain/memory_record.dart';
import 'package:orialis_mobile/features/memory/presentation/memory_page.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

class FakeMemoryRepository extends MemoryRepository {
  bool fail = false;
  @override
  Future<bool> requestAddTile() async => false;
  final records = <MemoryRecord>[
    MemoryRecord(
      id: 'bili',
      createdAt: DateTime.utc(2026, 10, 23),
      sourcePackage: 'tv.danmaku.bili',
      sourceLabel: '哔哩哔哩',
      visibleText: '电影里的科学',
      urls: const ['https://b23.tv/Test1'],
      title: '视频收藏',
      analysisStatus: 'pending',
    ),
    MemoryRecord(
      id: 'web',
      createdAt: DateTime.utc(2026, 10, 22),
      sourcePackage: 'browser',
      sourceLabel: '浏览器',
      visibleText: '配方',
      urls: const [],
      title: '今日菜单',
      summary: '早餐清单',
    ),
  ];
  @override
  Future<MemoryStatus> status() async => const MemoryStatus(supported: true);
  @override
  Future<List<MemoryRecord>> list() async {
    if (fail) throw StateError('read failed');
    return records;
  }

  @override
  Future<MemoryRecord> read(String id) async =>
      records.firstWhere((record) => record.id == id);
  @override
  Future<void> delete(String id) async {
    records.removeWhere((record) => record.id == id);
    notifyListeners();
  }
}

Future<void> showMemory(
  WidgetTester tester,
  FakeMemoryRepository repository, {
  Future<void> Function(MemoryRecord)? analyze,
}) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => LuminaTheme(
        child: Builder(
          builder: (context) => DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.bodyMedium,
            child: child!,
          ),
        ),
      ),
      home: MemoryPage(repository: repository, onAnalyze: analyze),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'organized first-paragraph preview omits repeated title and stays at two lines',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      repository.records[0] = MemoryRecord.fromMap({
        ...repository.records[0].toMap(),
        'summary': '# 视频收藏\n\n电影画面中的科学原理。\n值得保存的知识点。\n\n## 关键要点\n不要将整篇摘要放入卡片。',
      });
      await showMemory(tester, repository);
      final preview = find.text('电影画面中的科学原理。 值得保存的知识点。');
      expect(preview, findsOneWidget);
      expect(tester.widget<Text>(preview).maxLines, 2);
      expect(find.text('视频收藏'), findsOneWidget);
      expect(find.textContaining('不要将整篇摘要'), findsNothing);
    },
  );

  testWidgets(
    'detail presents organized summary and source links before original screenshot',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      repository.records[0] = MemoryRecord.fromMap({
        ...repository.records[0].toMap(),
        'summary': '# 视频收藏\n\n屏幕上讲述科学知识。',
        'imagePath': '/missing-test-capture.png',
        'analysisStatus': 'completed',
      });
      await showMemory(tester, repository);
      await tester.tap(find.text('视频收藏'));
      await tester.pumpAndSettle();
      final screenshot = find.byKey(
        const ValueKey('memory-original-screenshot'),
      );
      expect(screenshot, findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(SafeMarkdownView)).dy,
        lessThan(tester.getTopLeft(screenshot).dy),
      );
      expect(
        tester.getTopLeft(find.text('捕获到的链接')).dy,
        lessThan(tester.getTopLeft(screenshot).dy),
      );
    },
  );

  testWidgets('completed memories have no redundant analysis action', (
    tester,
  ) async {
    final repository = FakeMemoryRepository();
    addTearDown(repository.dispose);
    repository.records[0] = MemoryRecord.fromMap({
      ...repository.records[0].toMap(),
      'analysisStatus': 'completed',
    });
    await showMemory(tester, repository, analyze: (_) async {});
    await tester.tap(find.text('视频收藏'));
    await tester.pumpAndSettle();
    expect(find.text('开始理解'), findsNothing);
    expect(find.text('重试理解'), findsNothing);
    expect(find.text('Azure Hermes 已整理'), findsOneWidget);
  });

  testWidgets('Xiaohongshu memory shows original share text and signed URL', (
    tester,
  ) async {
    final repository = FakeMemoryRepository();
    addTearDown(repository.dispose);
    const url =
        'https://www.xiaohongshu.com/explore/123?xsec_token=abc%2Bdef&xsec_source=app_share';
    const original = '周末徒步路线\n$url';
    repository.records[0] = MemoryRecord.fromMap({
      ...repository.records[0].toMap(),
      'title': '小红书收藏',
      'sourcePackage': 'com.xingin.xhs',
      'sourceLabel': '小红书',
      'visibleText': '',
      'sharedText': original,
      'urls': [url],
    });
    await showMemory(tester, repository);
    expect(find.textContaining('小红书、哔哩哔哩'), findsOneWidget);
    await tester.tap(find.text('小红书收藏'));
    await tester.pumpAndSettle();
    final selectable = tester.widgetList<LuminaSelectableText>(
      find.byType(LuminaSelectableText),
    );
    expect(selectable.map((widget) => widget.data), contains(url));
    expect(selectable.map((widget) => widget.data), contains(original));
    expect(find.textContaining('不代表已获取笔记或视频全文'), findsOneWidget);
  });

  testWidgets(
    'manual tile instructions appear when Android cannot add automatically',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      await showMemory(tester, repository);
      expect(
        find.text('将「记住屏幕」加入控制中心。点击快捷按钮后，按安卓提示授权截屏，即可保存当前内容。'),
        findsOneWidget,
      );
      expect(find.text('启用屏幕记忆服务'), findsNothing);
      await tester.tap(find.text('添加快捷按钮'));
      await tester.pump();
      expect(find.text('下拉控制中心，编辑快捷按钮，将“记住屏幕”加入'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets(
    'failed analysis displays the safe reason and remains manually retryable',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      repository.records[0] = MemoryRecord.fromMap({
        ...repository.records[0].toMap(),
        'analysisStatus': 'failed',
        'analysisError': 'Azure Hermes 理解超时，截图和链接已保留，可稍后重试',
      });
      var retries = 0;
      await showMemory(tester, repository, analyze: (_) async => retries++);
      await tester.tap(find.text('视频收藏'));
      await tester.pumpAndSettle();
      expect(find.text('Azure Hermes 理解超时，截图和链接已保留，可稍后重试'), findsOneWidget);
      expect(retries, 0);
      await tester.tap(find.text('重试理解'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    },
  );

  testWidgets(
    'searches captured text and opens exact links without triggering duplicate analysis',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      var analyses = 0;
      await showMemory(tester, repository, analyze: (_) async => analyses++);
      expect(analyses, 0);
      expect(find.text('视频收藏'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '电影');
      await tester.pumpAndSettle();
      expect(find.text('今日菜单'), findsNothing);
      await tester.tap(find.text('视频收藏'));
      await tester.pumpAndSettle();
      expect(find.text('https://b23.tv/Test1'), findsOneWidget);
      expect(find.text('等待 Azure Hermes 理解'), findsOneWidget);
      expect(analyses, 0);
      await tester.tap(find.text('开始理解'));
      await tester.pumpAndSettle();
      expect(analyses, 1);
    },
  );

  testWidgets(
    'deletion requires confirmation and removes only selected record',
    (tester) async {
      final repository = FakeMemoryRepository();
      addTearDown(repository.dispose);
      await showMemory(tester, repository);
      await tester.tap(find.text('视频收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除记忆'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.records.length, 2);
      await tester.tap(find.text('删除记忆'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(repository.records.map((record) => record.id), ['web']);
      expect(find.text('今日菜单'), findsOneWidget);
    },
  );

  testWidgets('read failure shows retry instead of stale or empty success', (
    tester,
  ) async {
    final repository = FakeMemoryRepository()..fail = true;
    addTearDown(repository.dispose);
    await showMemory(tester, repository);
    expect(find.text('记忆未能读取，请确认已登录后重试'), findsOneWidget);
    expect(find.text('视频收藏'), findsNothing);
    repository.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('视频收藏'), findsOneWidget);
  });
}
