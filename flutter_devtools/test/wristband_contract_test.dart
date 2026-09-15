import 'package:flutter_test/flutter_test.dart';
import 'package:fangcun_devtools/wristband_contract.dart';

void main() {
  test('parses explicit unsupported capability without guessing vendor support', () {
    final capabilities = WristbandCapabilities.fromJson({
      'api': 'fangcun.wristband.v1',
      'available': false,
      'state': 'unsupported',
      'adapter': 'none',
      'transport': 'bluetooth-le',
      'features': {'heartRate': false, 'steps': false},
      'requiresPermissions': ['android.permission.BLUETOOTH_SCAN'],
    });

    expect(capabilities.state, WristbandState.unsupported);
    expect(capabilities.available, isFalse);
    expect(capabilities.supports('heartRate'), isFalse);
    expect(capabilities.requiresPermissions, contains('android.permission.BLUETOOTH_SCAN'));
  });

  test('unknown states fail safe to unsupported', () {
    expect(wristbandStateFromJson('future_state'), WristbandState.unsupported);
    expect(WristbandResult.fromJson({'ok': false, 'state': 'unsupported', 'error': 'unsupported'}).error, 'unsupported');
  });
}
