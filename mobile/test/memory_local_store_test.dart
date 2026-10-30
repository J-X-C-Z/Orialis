import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/memory/data/memory_local_store.dart';

void main() {
  late Directory root;
  late MemoryLocalStore store;
  const id = '12345678-1234-1234-1234-123456789abc';
  const accountA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const accountB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  Map<String, Object?> record() => {
    'id': id,
    'createdAt': '2026-10-31T00:00:00.000Z',
    'sourcePackage': 'test',
    'sourceLabel': 'source',
    'visibleText': 'original',
    'urls': <String>[],
    'title': 'title',
    'notes': 'user note',
    'cloudVersion': '1',
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('orialis-memory-cache-');
    store = MemoryLocalStore(rootDirectory: root);
    await store.handle('setScope', {'scope': accountA});
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'cloud cache keeps accounts separate and preserves local notes on conflict',
    () async {
      final initial = await store.handle('importCloud', {
        'record': record(),
        'expectedRecord': null,
      });
      await store.handle('update', {
        'id': id,
        'fields': {'notes': 'offline edit'},
      });
      await expectLater(
        store.handle('importCloud', {
          'record': {...record(), 'notes': 'remote edit'},
          'expectedRecord': initial,
        }),
        throwsStateError,
      );
      expect(
        (await store.handle('read', {'id': id}) as Map)['notes'],
        'offline edit',
      );
      await store.handle('setScope', {'scope': accountB});
      expect(await store.handle('list', {}), isEmpty);
      await store.handle('setScope', {'scope': accountA});
      expect((await store.handle('list', {}) as List).length, 1);
    },
  );

  test('cached image bytes round trip and stale cloud downloads cannot replace them', () async {
    await store.handle('importCloud', {
      'record': record(),
      'expectedRecord': null,
    });
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    final path = await store.handle('storeCloudImage', {
      'id': id,
      'bytes': bytes,
      'mimeType': 'image/png',
      'sha256': sha256.convert(bytes).toString(),
    }) as String;
    expect(await File(path).readAsBytes(), bytes);
    await store.handle('update', {
      'id': id,
      'fields': {'cloudImageSha256': sha256.convert(bytes).toString()},
    });
    await expectLater(
      store.handle('storeCloudImage', {
        'id': id,
        'bytes': Uint8List.fromList([1, 2]),
        'mimeType': 'image/png',
        'sha256': sha256.convert([1, 2]).toString(),
      }),
      throwsStateError,
    );
    expect(await File(path).readAsBytes(), bytes);
    await store.handle('delete', {'id': id});
    expect(await File(path).exists(), isTrue);
    expect(
      (await store.handle('read', {'id': id}) as Map)['cloudDeletedAt'],
      'pending',
    );
  });

  test(
    'delayed old-account import cannot create a record in a new account',
    () async {
      await store.handle('setScope', {'scope': accountB});
      await expectLater(
        store.handle('importCloud', {
          'record': record(),
          'expectedRecord': null,
          'expectedScope': accountA,
        }),
        throwsStateError,
      );
      expect(await store.handle('list', {}), isEmpty);
    },
  );

  test(
    'cloud compressed copy never replaces a locally retained original',
    () async {
      await store.handle('importCloud', {
        'record': record(),
        'expectedRecord': null,
      });
      final original = Uint8List.fromList([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        10,
      ]);
      final originalPath = await store.handle('storeCloudImage', {
        'id': id,
        'bytes': original,
        'mimeType': 'image/png',
        'sha256': sha256.convert(original).toString(),
      }) as String;
      final compressed = Uint8List.fromList([255, 216, 255, 1]);
      final cloudHash = sha256.convert(compressed).toString();
      await store.handle('update', {
        'id': id,
        'fields': {'cloudImageSha256': cloudHash},
      });
      expect(
        await store.handle('storeCloudImage', {
          'id': id,
          'bytes': compressed,
          'mimeType': 'image/jpeg',
          'sha256': cloudHash,
        }),
        originalPath,
      );
      expect(await File(originalPath).readAsBytes(), original);
    },
  );

  test(
    'rejects external paths and unsafe account or record identifiers',
    () async {
      await expectLater(
        store.handle('setScope', {'scope': '../another-account'}),
        throwsFormatException,
      );
      await expectLater(
        store.handle('read', {'id': '../../file'}),
        throwsFormatException,
      );
      await expectLater(
        store.handle('importCloud', {
          'record': {...record(), 'imagePath': '/private/sensitive'},
          'expectedRecord': null,
        }),
        throwsFormatException,
      );
      expect(await store.handle('read', {'id': id}), isNull);
    },
  );
}
