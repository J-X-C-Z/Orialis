import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/application/response_action_service.dart';
import 'package:orialis_mobile/features/chat/domain/response_action_schema.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_attachment.dart';
import 'package:orialis_mobile/features/chat/presentation/response_action_blocks.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';

const _task = <String, dynamic>{
  'id': 'study',
  'label': '安排复习',
  'kind': 'task',
  'title': '复习傅里叶级数',
  'due': '2026-10-26',
  'notes': '先看例题',
};
const _schedule = <String, dynamic>{
  'id': 'session',
  'label': '学习日程',
  'kind': 'schedule',
  'title': '学习',
  'startAt': '2026-10-26T09:00:00+08:00',
  'endAt': '2026-10-26T10:00:00+08:00',
  'location': '图书馆',
};

Widget _host(Widget child, {AppDatabase? db, ResponseActionService? service}) =>
    ProviderScope(
      overrides: [
        if (db != null) databaseProvider.overrideWithValue(db),
        if (service != null)
          responseActionServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        home: LuminaTheme(
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(width: 240, child: child),
              ),
            ),
          ),
        ),
      ),
    );

Widget _card({String scope = 'conversation:message', bool enabled = true}) =>
    ResponseActionBlock(
      data: {
        'type': 'actions',
        'items': [_task],
      },
      enabled: enabled,
      scope: scope,
    );

class _FailOnce extends ResponseActionService {
  _FailOnce(super.events);
  bool fail = true;
  @override
  Future<ResponseActionReceipt> create(
    String scope,
    Map<String, dynamic> item,
  ) {
    if (fail) {
      fail = false;
      throw StateError('test failure');
    }
    return super.create(scope, item);
  }
}

class _DownloadConfig extends AppConfig {
  _DownloadConfig(this.url);
  final String url;
  @override
  Future<String> serverUrl() async => url;
  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<String?> sessionToken() async => 'test-session';
}

class _SwitchingEvents extends EventRepository {
  _SwitchingEvents({required super.database, required super.config});
  @override
  Future<void> createTask({
    required String title,
    String? notes,
    String? due,
    String? dueTime,
    bool? important,
    bool? urgent,
    int? reminderMinutes,
    TaskRecurrence? recurrence,
    String? projectId,
    String? parentTaskId,
    String? scheduleId,
  }) async {
    await super.createTask(title: title, notes: notes, due: due);
    await config.setSessionUsername('other-account');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'action schema rejects invalid dates, timezone-free ranges and path ids',
    () {
      expect(
        validateActionResponseBlock({
          'type': 'actions',
          'items': [_task, _schedule],
        }),
        isTrue,
      );
      for (final item in [
        {..._task, 'due': '2026-02-30'},
        {..._task, 'id': '../secret'},
        {..._schedule, 'startAt': '2026-10-26T09:00:00'},
        {..._schedule, 'endAt': '2026-10-26T08:00:00+08:00'},
        {..._schedule, 'startAt': '2026-10-26T24:00:00Z'},
        {..._schedule, 'startAt': '2026-10-26T09:00:00+25:00'},
      ]) {
        expect(
          validateActionResponseBlock({
            'type': 'actions',
            'items': [item],
          }),
          isFalse,
        );
      }
      expect(
        validateActionResponseBlock({
          'type': 'media',
          'items': [
            {
              'label': '文档',
              'id': 'attachment-1',
              'mimeType': 'application/pdf',
            },
          ],
        }),
        isTrue,
      );
    },
  );

  test(
    'creates real rows and outbox with durable scoped dedup and live status',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final events = EventRepository(database: db, config: AppConfig());
      final service = ResponseActionService(events);
      final results = await Future.wait([
        service.create('message-1', _task),
        service.create('message-1', _task),
      ]);
      expect(results.map((r) => r.entityId).toSet(), hasLength(1));
      final task = await db.select(db.tasks).getSingle();
      expect(task.notes, '先看例题');
      expect(task.syncStatus, 'pendingCreate');
      expect(
        (await db.select(db.outboxMutations).get()).single.entityId,
        task.id,
      );
      expect(
        (await ResponseActionService(
          events,
        ).create('message-1', _task)).entityId,
        task.id,
      );
      await (db.update(db.tasks)..where((r) => r.id.equals(task.id))).write(
        const TasksCompanion(syncStatus: Value('synced')),
      );
      expect((await service.lookup('message-1', _task))!.message, '已同步');
      await events.deleteTask((await db.select(db.tasks).getSingle()));
      expect((await service.create('message-1', _task)).removed, isTrue);
      expect(await db.select(db.tasks).get(), hasLength(1));
      await service.create('message-2', _task);
      expect(await db.select(db.tasks).get(), hasLength(2));
      final schedule = await service.create('message-3', _schedule);
      final row = await db.select(db.calendarEvents).getSingle();
      expect(row.id, schedule.entityId);
      expect(row.startAt, '2026-10-26T01:00:00.000Z');
      expect(schedule.message, '已保存在本机，等待同步');
    },
  );

  test(
    'identity change during create rolls back rows, outbox and receipt',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final service = ResponseActionService(
        _SwitchingEvents(database: db, config: AppConfig()),
      );
      await expectLater(service.create('message', _task), throwsStateError);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await db.select(db.outboxMutations).get(), isEmpty);
      expect(await db.select(db.syncMetadata).get(), isEmpty);
    },
  );

  testWidgets('disabled action preview needs no provider or database', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LuminaTheme(child: Scaffold(body: _card(enabled: false))),
      ),
    );
    expect(find.text('复习傅里叶级数\n先看例题\n截止日期：2026-10-26'), findsOneWidget);
    expect(
      tester.widget<LuminaButton>(find.byType(LuminaButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmation cancels, retries errors, creates once and restores receipt',
    (tester) async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final service = _FailOnce(
        EventRepository(database: db, config: AppConfig()),
      );
      await tester.pumpWidget(_host(_card(), db: db, service: service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览并创建任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.select(db.tasks).get()), isEmpty);
      await tester.tap(find.text('预览并创建任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认创建'));
      await tester.pumpAndSettle();
      expect(find.text('创建失败，请重试'), findsOneWidget);
      await tester.tap(find.text('预览并创建任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认创建'));
      await tester.pumpAndSettle();
      expect(find.text('已保存在本机，等待同步'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.tasks).get()),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(_card(), db: db, service: service));
      await tester.pumpAndSettle();
      expect(find.text('已保存在本机，等待同步'), findsOneWidget);
      expect(find.text('预览并创建任务'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('media cards reference attachments without automatic downloads', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ResponseActionBlock(
          data: {
            'type': 'media',
            'items': [
              {'label': '图像', 'id': 'img-1', 'mimeType': 'image/png'},
              {'label': '两页文档', 'id': 'pdf-1', 'mimeType': 'application/pdf'},
            ],
          },
          enabled: false,
          scope: 'media',
        ),
      ),
    );
    expect(find.byType(ChatAttachmentTile), findsNWidgets(2));
    expect(find.text('两页文档'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment download and explicit share dispatch actual bytes', (
    tester,
  ) async {
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = oldOverrides);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('response-ui-share-'),
    ))!;
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    var downloads = 0;
    final requestedIds = <String>[];
    server.listen((request) async {
      downloads++;
      requestedIds.add(request.uri.path);
      expectSync(
        request.headers.value('Authorization'),
        'Session test-session',
      );
      if (request.uri.path.contains('/img-')) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2V8AAAAASUVORK5CYII=',
          ),
        );
      } else {
        request.response.headers.contentType = ContentType.text;
        request.response.write('generated report');
      }
      await request.response.close();
    });
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const sharing = MethodChannel('dev.fluttercommunity.plus/share');
    Map<dynamic, dynamic>? payload;
    var fail = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => root.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(sharing, (
      call,
    ) async {
      if (fail) throw PlatformException(code: 'share_failed');
      payload = call.arguments as Map;
      return 'selected-test-application';
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        sharing,
        null,
      );
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final config = _DownloadConfig('http://127.0.0.1:${server.port}');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const MaterialApp(
          home: LuminaTheme(
            child: Scaffold(
              body: ResponseActionBlock(
                data: {
                  'type': 'media',
                  'items': [
                    {
                      'label': '报告',
                      'id': 'report-1',
                      'mimeType': 'text/plain',
                      'name': 'report.txt',
                    },
                    {'label': '图一', 'id': 'img-1', 'mimeType': 'image/png'},
                    {'label': '图二', 'id': 'img-2', 'mimeType': 'image/png'},
                  ],
                },
                enabled: true,
                scope: 'media',
              ),
            ),
          ),
        ),
      ),
    );
    expect(downloads, 0);
    await tester.tap(find.text('report.txt'));
    for (
      var i = 0;
      i < 50 && find.text('generated report').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('generated report'), findsOneWidget);
    expect(downloads, 1);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '分享附件',
      ),
    );
    for (var i = 0; i < 50 && payload == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(payload, isNotNull);
    final path = (payload!['paths'] as List).single as String;
    expect(
      await tester.runAsync(() => File(path).readAsString()),
      'generated report',
    );
    fail = true;
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '分享附件',
      ),
    );
    for (
      var i = 0;
      i < 50 && find.text('暂时无法分享，请保存附件后分享').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('暂时无法分享，请保存附件后分享'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '返回聊天',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('图一'));
    for (var i = 0; i < 50 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(requestedIds.last, contains('/img-1/'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '下一张图片',
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<LuminaIconButton>(
            find.byWidgetPredicate(
              (w) => w is LuminaIconButton && w.tooltip == '分享附件',
            ),
          )
          .onPressed,
      isNull,
    );
    for (var i = 0; i < 50 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(requestedIds.last, contains('/img-2/'));
    await config.setServerUrl('https://other.example');
    await tester.pump();
    expect(find.text('登录已改变，请重新打开附件'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test(
    'native PDF engine opens and renders generated two-page document',
    () async {
      final module = Platform.isWindows
          ? 'pdfium.dll'
          : Platform.isMacOS
          ? 'libpdfium.dylib'
          : 'libpdfium.so';
      final asset = File(
        'build/native_assets/${Platform.operatingSystem}/$module',
      );
      if (asset.existsSync()) Pdfrx.pdfiumModulePath = asset.absolute.path;
      await pdfrxInitialize();
      final doc = await PdfDocument.openData(
        _twoPagePdf(),
        sourceName: 'response-ui-test',
        useProgressiveLoading: false,
      );
      try {
        expect(doc.pages, hasLength(2));
        for (final page in doc.pages) {
          final image = await page.render(width: 120, height: 120);
          expect(image, isNotNull);
          image!.dispose();
        }
      } finally {
        await doc.dispose();
      }
    },
  );
}

Uint8List _twoPagePdf() {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}
