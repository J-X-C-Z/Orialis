import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shortcut recording calls the actual native suspend and resume methods',
    () async {
      const channel = MethodChannel('top.jxcz.orialis/memory');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method != 'suspendShortcuts' &&
                call.method != 'resumeShortcuts') {
              throw MissingPluginException('Unknown native method');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final repository = MemoryRepository(channel: channel);
      addTearDown(repository.dispose);
      await repository.setShortcutRecording(true);
      await repository.setShortcutRecording(false);
      expect(calls.map((call) => call.method), [
        'suspendShortcuts',
        'resumeShortcuts',
      ]);
      expect(calls.every((call) => call.arguments == null), isTrue);
    },
  );
}
