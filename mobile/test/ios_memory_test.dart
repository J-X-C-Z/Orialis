import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'iOS cloud-memory cache works without an Android capture bridge',
    () async {
      final repository = MemoryRepository();
      addTearDown(repository.dispose);
      final status = await repository.status();
      expect(status.supported, isTrue);
      expect(status.captureSupported, isFalse);
      expect(status.silentCaptureSupported, isFalse);
      await repository.setScope(null);
      expect(await repository.list(), isEmpty);
      expect(await repository.takePendingRoute(), isNull);
      expect(await repository.requestAddTile(), isFalse);
    },
  );

  test('iOS starts the existing memory cloud coordinator', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(memoryCoordinatorProvider), isNotNull);
    expect(container.read(systemIntegrationProvider), isNull);
    expect(container.read(chatShareCoordinatorProvider), isNull);
  });
}
