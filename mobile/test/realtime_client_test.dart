import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://localhost';
  @override
  Future<String> deviceId() async => 'test-device';
}

void main() {
  test(
    'hello.ack negotiates server capabilities through the event seam',
    () async {
      final client = MobileRealtimeClient(config: _Config());
      addTearDown(client.dispose);

      client.ingestForTest(
        '{"type":"hello.ack","payload":{"capabilities":["agent.status","tool.timeline"]}}',
      );

      expect(client.capabilitiesNegotiated, isTrue);
      expect(
        client.capabilities,
        containsAll(['agent.status', 'tool.timeline']),
      );
    },
  );

  test(
    'disconnect schedules bounded reconnect and dispose cancels it',
    () async {
      final client = MobileRealtimeClient(config: _Config());

      client.simulateDisconnectForTest();
      expect(client.reconnectScheduled, isTrue);
      await client.dispose();
      expect(client.reconnectScheduled, isFalse);
    },
  );
}
