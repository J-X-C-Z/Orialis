import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/attachments/attachment_bridge.dart';

void main() {
  test(
    'imports a selected file into the private persistent directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'orialis-attachments-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/photo.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final destination = Directory('${root.path}/app-support');
      final bridge = AttachmentBridge(
        directoryProvider: () async => destination,
      );

      final record = await bridge.importFile(source.path);

      expect(record.status, AttachmentStatus.pending);
      expect(record.localPath, isNot(source.path));
      expect(await File(record.localPath).readAsBytes(), [1, 2, 3]);
      expect(record.name, 'photo.jpg');
      expect(record.mimeType, 'image/jpeg');
    },
  );

  test(
    'round-trips retry state and excludes local bridge fields from API data',
    () {
      final record = const AttachmentRecord(
        localPath: '/private/attachment.bin',
        name: 'attachment.bin',
        mimeType: 'application/octet-stream',
        size: 42,
        status: AttachmentStatus.failed,
        attempts: 2,
        lastError: 'timeout',
        lastAttemptAt: '2026-09-17T00:00:00Z',
      );
      final decoded = AttachmentBridge.decode(
        AttachmentBridge.encode([record]),
      ).single;

      expect(decoded.status, AttachmentStatus.failed);
      expect(decoded.attempts, 2);
      expect(decoded.lastError, 'timeout');
      expect(decoded.toMessageJson({'id': 'att-1'}), {
        'id': 'att-1',
      });
      expect(
        decoded.toMessageJson({'id': 'att-1'}),
        isNot(contains('localPath')),
      );
    },
  );
}
