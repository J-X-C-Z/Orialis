import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'session token commit notifies listeners after secure persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final config = AppConfig();
      final committedTokens = <String?>[];
      config.addIdentityCommittedListener(() async {
        committedTokens.add(await config.sessionToken());
      });

      await config.setSessionToken('new-session');

      expect(committedTokens, ['new-session']);
    },
  );

  test('new token never commits with the previous username', () async {
    SharedPreferences.setMockInitialValues({
      'orialis.sessionUsername': 'alice',
    });
    FlutterSecureStorage.setMockInitialValues({
      'orialis.sessionToken': 'alice-token',
    });
    final config = AppConfig();
    final names = <String?>[];
    config.addIdentityCommittedListener(() async {
      names.add(await config.sessionUsername());
    });
    await config.setSessionToken('bob-token');
    await config.setSessionUsername('bob');
    expect(names, [null, 'bob']);
    await config.setSessionUsername('bob');
    expect(names, [null, 'bob']);
  });
}
