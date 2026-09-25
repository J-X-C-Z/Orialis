import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'high performance mode defaults on and persists a user choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final config = AppConfig();
      expect(await config.highPerformanceMode(), isTrue);
      await config.setHighPerformanceMode(false);
      expect(await AppConfig().highPerformanceMode(), isFalse);
      await config.setHighPerformanceMode(true);
      expect(await AppConfig().highPerformanceMode(), isTrue);
    },
  );
}
