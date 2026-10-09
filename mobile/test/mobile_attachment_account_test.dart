import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/attachments/attachment_bridge.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

class _AttachmentAccountConfig extends AppConfig {
  _AttachmentAccountConfig(this.baseUrl);
  final String baseUrl;
  String username = 'alice';

  @override
  Future<String> serverUrl() async => baseUrl;
  @override
  Future<String?> sessionUsername() async => username;
  @override
  Future<String?> sessionToken() async => 'synthetic-$username';
  @override
  Future<String> deviceId() async => 'synthetic-attachment-phone';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real mobile providers keep imported attachment bytes private across A B A startup and retry', () async {
    // Exercise real loopback HTTP, rather than the widget binding's HTTP 400.
    final originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = originalHttpOverrides);
    final root = await Directory.systemTemp.createTemp('ori106-attachment-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getTemporaryDirectory') return root.path;
          throw UnsupportedError('unexpected path lookup: ${call.method}');
        });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uploads = <({String? account, List<int> body, String? key})>[];
    final messages = <({String? account, Map<String, dynamic> body})>[];
    var failUpload = true;
    final config = _AttachmentAccountConfig('http://127.0.0.1:${server.port}');
    ProviderContainer? container;
    AppDatabase? database;

    Future<void> closeAccount() async {
      container?.dispose();
      container = null;
      await database?.close();
      database = null;
    }

    addTearDown(() async {
      await closeAccount();
      await server.close(force: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      await root.delete(recursive: true);
    });
    server.listen((request) async {
      final bytes = await request.fold<List<int>>(
        [],
        (body, chunk) => body..addAll(chunk),
      );
      final account = request.headers.value('Authorization');
      Object response = {'items': []};
      final path = request.uri.path;
      if (path == '/api/v1/conversations') response = [];
      if (request.method == 'POST' && path.endsWith('/attachments')) {
        uploads.add((
          account: account,
          body: bytes,
          key: request.headers.value('Idempotency-Key'),
        ));
        if (failUpload) {
          request.response.statusCode = 503;
          response = {'error': 'synthetic upload failure'};
        } else {
          response = {
            'items': [
              {
                'id': 'alice-attachment',
                'downloadUrl': '${config.baseUrl}/download',
              },
            ],
          };
        }
      } else if (request.method == 'POST' && path.endsWith('/messages')) {
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        messages.add((account: account, body: body));
        response = {'id': body['id'], 'version': 1};
      } else if (path == '/api/v1/sync/snapshot') {
        response = {
          'cursor': 0,
          'tasks': [],
          'calendarEvents': [],
          'projects': [],
          'milestones': [],
        };
      } else if (path == '/api/v1/sync/events') {
        response = {'nextCursor': 0, 'events': [], 'hasMore': false};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });

    Future<ProviderContainer> startAccount(String username) async {
      await closeAccount();
      config.username = username;
      container = ProviderContainer(
        overrides: [
          ...await mobileStartupOverrides(config),
          databaseDirectoryProvider.overrideWithValue(() async => root),
        ],
      );
      database = container!.read(databaseProvider);
      return container!;
    }

    var account = await startAccount('alice');
    final aliceScope = account.read(desktopDatabaseNameProvider);
    // Match the production shared cache layout; isolation must come from
    // actual account DB selection, rather than an artificial per-user folder.
    final payload = <int>[0, 255, 65, 45, 111, 110, 108, 121, 13, 10, 128];
    final source = File('${root.path}/A-private.bin');
    await source.writeAsBytes(payload);
    final record = await AttachmentBridge(
      directoryProvider: () async => Directory('${root.path}/attachments'),
    ).importFile(source.path);
    await source.delete();
    expect(await File(record.localPath).readAsBytes(), payload);
    final pending = await account
        .read(chatRepositoryProvider)
        .sendMessage(
          conversationId: 'default',
          content: '',
          attachmentsJson: AttachmentBridge.encode([record]),
        );

    expect(await account.read(syncEngineProvider).syncOnce(), SyncState.error);
    expect(uploads, hasLength(1));
    expect(uploads.single.account, 'Session synthetic-alice');
    expect(
      latin1.decode(uploads.single.body),
      contains(latin1.decode(payload)),
    );
    expect(uploads.single.key, '${pending.id}:attachment:0');
    expect(messages, isEmpty);
    final failed = await database!.select(database!.messages).getSingle();
    final failedRecord = AttachmentBridge.decode(failed.attachmentsJson).single;
    expect(failedRecord.status, AttachmentStatus.failed);
    expect(failedRecord.localPath, record.localPath);
    expect(failedRecord.attempts, 1);

    account = await startAccount('bob');
    expect(account.read(desktopDatabaseNameProvider), isNot(aliceScope));
    expect(await database!.select(database!.messages).get(), isEmpty);
    expect(await database!.select(database!.outboxMutations).get(), isEmpty);
    expect(await database!.select(database!.syncMetadata).get(), isEmpty);
    // B performs a real successful message sync, while A's pending file is
    // still physically present in the same shared attachment directory.
    await account
        .read(chatRepositoryProvider)
        .sendMessage(conversationId: 'default', content: 'synthetic B text');
    failUpload = false;
    expect(await account.read(syncEngineProvider).syncOnce(), SyncState.idle);
    expect(uploads, hasLength(1));
    expect(messages, hasLength(1));
    expect(messages.single.account, 'Session synthetic-bob');
    expect(messages.single.body['attachments'], isEmpty);
    expect(messages.single.body['id'], isNot(pending.id));
    expect(await File(record.localPath).readAsBytes(), payload);

    account = await startAccount('alice');
    expect(account.read(desktopDatabaseNameProvider), aliceScope);
    expect(await database!.select(database!.messages).getSingle(), failed);
    expect(await File(record.localPath).readAsBytes(), payload);
    expect(await account.read(syncEngineProvider).syncOnce(), SyncState.idle);
    expect(uploads, hasLength(2));
    expect(uploads.last.account, 'Session synthetic-alice');
    expect(latin1.decode(uploads.last.body), contains(latin1.decode(payload)));
    expect(uploads.last.key, uploads.first.key);
    expect(messages, hasLength(2));
    expect(messages.last.account, 'Session synthetic-alice');
    expect(messages.last.body['id'], pending.id);
    expect(messages.last.body['attachments'], [
      {'id': 'alice-attachment'},
    ]);
    expect(jsonEncode(messages.last.body), isNot(contains(root.path)));
    final saved = await database!.select(database!.messages).getSingle();
    expect(saved.syncStatus, 'synced');
    final savedRecord = AttachmentBridge.decode(saved.attachmentsJson).single;
    expect(savedRecord.isUploaded, isTrue);
    expect(savedRecord.attempts, 2);
    expect(await File(savedRecord.localPath).readAsBytes(), payload);
  });
}
