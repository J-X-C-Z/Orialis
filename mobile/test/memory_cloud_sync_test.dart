import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/memory/application/memory_cloud_sync.dart';
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';
import 'package:orialis_mobile/features/memory/domain/memory_record.dart';

const id = '11111111-1111-4111-8111-111111111111';
MemoryRecord record({String? imagePath, String notes = '我的笔记'}) => MemoryRecord(
  id: id,
  createdAt: DateTime.utc(2026, 10, 31),
  sourcePackage: 'test',
  sourceLabel: '来源',
  visibleText: '不可替代的原文',
  urls: const ['https://example.org/source?keep=1'],
  title: '记忆标题',
  notes: notes,
  summary: '# 摘要\n\n重点内容',
  imagePath: imagePath,
  analysisStatus: 'completed',
  category: 'other',
);
MemoryRecord copy(MemoryRecord value, Map<String, Object?> fields) =>
    MemoryRecord.fromMap({...value.toMap(), ...fields});

class Inbox extends MemoryRepository {
  final values = <String, MemoryRecord>{};
  String? boundScope;
  @override
  String? get accountScope => boundScope;
  final storedImages = <String, Uint8List>{};
  final uploadCopies = <String, String>{};
  int prepareRequests = 0;
  @override
  Future<String> prepareUpload(String id) async {
    prepareRequests++;
    return uploadCopies[id] ?? (throw StateError('missing compressed copy'));
  }

  @override
  Future<List<MemoryRecord>> listAll() async => values.values.toList();
  @override
  Future<MemoryRecord> read(String id) async => values[id]!;
  @override
  Future<MemoryRecord> update(
    String id,
    Map<String, Object?> fields, {
    String? expectedAnalysisRequestId,
  }) async {
    final value = values[id] = copy(values[id]!, fields);
    notifyListeners();
    return value;
  }

  @override
  Future<MemoryRecord> importCloud(
    Map<String, Object?> incoming,
    MemoryRecord? expected, {
    String? expectedScope,
  }) async {
    final current = values[incoming['id']];
    if (jsonEncode(current?.toMap()) != jsonEncode(expected?.toMap())) {
      throw StateError('CAS');
    }
    return values[incoming['id'] as String] = MemoryRecord.fromMap({
      ...?current?.toMap(),
      ...incoming,
      if (current?.imagePath != null) 'imagePath': current!.imagePath,
    });
  }

  @override
  Future<void> storeCloudImage(
    String id,
    Uint8List bytes,
    String mimeType,
    String sha256, {
    String? expectedScope,
  }) async {
    storedImages[id] = bytes;
  }
}

class Cloud extends OrialisApiClient {
  Cloud() : super(baseUrl: 'https://unused.invalid', deviceId: 'test');
  final values = <String, Map<String, dynamic>>{};
  final images = <String, Uint8List>{};
  final operations = <String>[];
  bool offline = false;
  int pageSize = 100, puts = 0;
  void Function()? onList, onPut;
  @override
  Future<Map<String, dynamic>> memoryRecords({
    int offset = 0,
    int limit = 100,
    String? query,
  }) async {
    if (offline) throw const SocketException('offline');
    onList?.call();
    operations.add('list:$offset');
    final all = values.values.toList();
    return {
      'items': all.skip(offset).take(pageSize).toList(),
      'hasMore': offset + pageSize < all.length,
    };
  }

  @override
  Future<Map<String, dynamic>> putMemoryRecord(
    String id,
    Map<String, Object?> record,
    int version,
  ) async {
    final previous = values[id];
    if ((previous?['version'] ?? 0) != version) {
      throw DioException(
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: 409),
      );
    }
    operations.add('put');
    puts++;
    final result = values[id] = {
      ...record,
      'version': version + 1,
      'updatedAt': '2026-10-31T00:00:00Z',
      'deletedAt': null,
    };
    final callback = onPut;
    onPut = null;
    callback?.call();
    return result;
  }

  @override
  Future<Map<String, dynamic>> deleteMemoryRecord(
    String id,
    int version,
  ) async {
    expect(values[id]!['version'], version);
    return values[id] = {
      ...values[id]!,
      'version': version + 1,
      'deletedAt': '2026-10-31T01:00:00Z',
    };
  }

  @override
  Future<void> uploadMemoryImage(
    String hash,
    Uint8List bytes,
    String mimeType,
  ) async {
    operations.add('image');
    images[hash] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> downloadMemoryImage(String hash) async => images[hash]!;
}

class Agents extends AgentChatService {
  Agents(this.api) : super(AppConfig());
  final Cloud api;
  (String, String) current = ('https://unused.invalid', 'account-a');
  @override
  Future<(String, String)> identity() async => current;
  @override
  Future<OrialisApiClient> client() async => api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Inbox inbox;
  late Cloud cloud;
  late Agents agents;
  late MemoryCloudSync sync;
  setUp(() {
    inbox = Inbox();
    cloud = Cloud();
    agents = Agents(cloud);
    sync = MemoryCloudSync(repository: inbox, agents: agents);
  });
  tearDown(() {
    sync.dispose();
    agents.dispose();
    inbox.dispose();
    cloud.close();
  });

  test('offline keeps original and note; reconnect uploads and a second device can query them', () async {
    inbox.values[id] = record();
    cloud.offline = true;
    await sync.sync();
    expect(sync.hasPending, isTrue);
    expect(inbox.values[id]!.notes, '我的笔记');
    expect(inbox.values[id]!.cloudVersion, isNull);
    expect(cloud.values, isEmpty);
    cloud.offline = false;
    await sync.sync();
    expect(inbox.values[id]!.cloudVersion, '1');
    expect(sync.hasPending, isFalse);
    final second = Inbox();
    final secondSync = MemoryCloudSync(repository: second, agents: agents);
    await secondSync.sync();
    expect(second.values[id]!.visibleText, '不可替代的原文');
    expect(second.values[id]!.notes, '我的笔记');
    expect(second.values[id]!.matches('笔记'), isTrue);
    expect(cloud.puts, 1);
    secondSync.dispose();
    second.dispose();
  });

  test('uploads compressed copy bytes while retaining local original and verifies downloaded cloud hash', () async {
    final temp = await Directory.systemTemp.createTemp(
      'memory-cloud-original-',
    );
    try {
      final bytes = Uint8List.fromList([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        ...List.generate(8192, (i) => i % 256),
      ]);
      final file = File('${temp.path}/original.png');
      await file.writeAsBytes(bytes);
      inbox.values[id] = record(imagePath: file.path);
      final compressed = Uint8List.fromList([
        255,
        216,
        255,
        224,
        ...List.generate(512, (i) => i % 256),
        255,
        217,
      ]);
      final copyFile = File('${temp.path}/upload.jpg');
      await copyFile.writeAsBytes(compressed);
      inbox.uploadCopies[id] = copyFile.path;
      await sync.sync();
      final hash = sha256.convert(compressed).toString();
      expect(cloud.images[hash], compressed);
      expect(compressed.length, lessThan(bytes.length));
      expect(cloud.values[id]!['imageSha256'], hash);
      expect(
        cloud.operations.indexOf('image'),
        lessThan(cloud.operations.indexOf('put')),
      );
      expect(await file.readAsBytes(), bytes);
      final second = Inbox();
      final other = MemoryCloudSync(repository: second, agents: agents);
      await other.sync();
      expect(second.storedImages[id], compressed);
      expect(inbox.prepareRequests, 1);
      other.dispose();
      second.dispose();
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('pulls all pages and does not upload clean imports again', () async {
    cloud.pageSize = 1;
    for (var i = 1; i <= 3; i++) {
      final nextId =
          '${i.toString().padLeft(8, '0')}-1111-4111-8111-111111111111';
      cloud.values[nextId] = {
        ...record().toCloudMap(),
        'id': nextId,
        'version': 1,
        'deletedAt': null,
      };
    }
    await sync.sync();
    expect(inbox.values.length, 3);
    expect(cloud.operations, containsAll(['list:0', 'list:1', 'list:2']));
    expect(cloud.puts, 0);
  });

  test(
    'account changes during cloud response never import old account records',
    () async {
      cloud.values[id] = {
        ...record().toCloudMap(),
        'version': 1,
        'deletedAt': null,
      };
      cloud.onList = () =>
          agents.current = ('https://unused.invalid', 'account-b');
      await sync.sync();
      expect(inbox.values, isEmpty);
      expect(cloud.puts, 0);
    },
  );

  test('native account scope changes abort even if the HTTP session has not switched yet', () async {
    inbox.boundScope = 'account-a';
    cloud.values[id] = {
      ...record().toCloudMap(),
      'version': 1,
      'deletedAt': null,
    };
    cloud.onList = () => inbox.boundScope = 'account-b';
    await sync.sync();
    expect(inbox.values, isEmpty);
  });

  test('deleting an unsynced memory does not require its unavailable original image', () async {
    inbox.values[id] = record(imagePath: '/missing/original.png');
    await inbox.delete(id);
    await sync.sync();
    expect(inbox.values[id]!.cloudDeletedAt, isNot('pending'));
    expect(inbox.values[id]!.visibleText, '不可替代的原文');
    expect(cloud.values, isEmpty);
  });

  test('a note edited while upload is in flight survives and is uploaded in the next pass', () async {
    inbox.values[id] = record(notes: '旧笔记');
    cloud.onPut = () {
      inbox.values[id] = copy(inbox.values[id]!, {'notes': '上传期间的新笔记'});
    };
    await sync.sync();
    expect(inbox.values[id]!.notes, '上传期间的新笔记');
    expect(cloud.values[id]!['notes'], '上传期间的新笔记');
    expect(cloud.values[id]!['version'], 2);
    expect(inbox.values[id]!.cloudVersion, '2');
  });

  test('concurrent remote and local note changes retain local data and show conflict', () async {
    inbox.values[id] = record();
    await sync.sync();
    inbox.values[id] = copy(inbox.values[id]!, {'notes': '本机新笔记'});
    cloud.values[id] = {
      ...cloud.values[id]!,
      'notes': '另一台设备的新笔记',
      'version': 2,
    };
    await sync.sync();
    expect(inbox.values[id]!.notes, '本机新笔记');
    expect(cloud.values[id]!['notes'], '另一台设备的新笔记');
    expect(inbox.values[id]!.cloudSyncError, contains('本机修改已保留'));
    expect(sync.hasPending, isTrue);
  });

  test(
    'deletion synchronizes tombstone and keeps local original record',
    () async {
      inbox.values[id] = record();
      await sync.sync();
      await inbox.delete(id);
      await sync.sync();
      expect(inbox.values[id]!.visibleText, '不可替代的原文');
      expect(inbox.values[id]!.cloudDeletedAt, '2026-10-31T01:00:00Z');
      expect(cloud.values[id]!['deletedAt'], isNotNull);
    },
  );
}
