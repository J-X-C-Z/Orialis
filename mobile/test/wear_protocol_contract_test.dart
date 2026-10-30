import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/wear/wear_protocol.dart';

void main() {
  test('phone transfer limits match the band receiver contract', () {
    final bandProtocol = File('../band/vela/src/common/protocol.js')
        .readAsStringSync();

    int bandLimit(String name) {
      final match = RegExp('const $name = (\\d+)').firstMatch(bandProtocol);
      expect(match, isNotNull, reason: 'band protocol must define $name');
      return int.parse(match!.group(1)!);
    }

    expect(WearProtocol.maxSnapshotBytes, bandLimit('MAX_TRANSFER_BYTES'));
    expect(WearProtocol.maxParts, bandLimit('MAX_PARTS'));
  });
}
