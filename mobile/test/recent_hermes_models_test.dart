import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/chat/data/recent_hermes_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'keeps five distinct successful selections across store instances',
    () async {
      final history = RecentHermesModels();
      for (final model in ['a', 'b', 'c', 'd', 'e', 'f']) {
        await history.recordSuccessfulSwitch(model);
      }
      await history.recordSuccessfulSwitch(' c ');

      expect(await RecentHermesModels().load(), ['c', 'f', 'e', 'd', 'b']);
    },
  );

  test(
    'ignores blank selections and sanitises legacy or malformed history',
    () async {
      SharedPreferences.setMockInitialValues({
        RecentHermesModels.storageKey: <String>[
          ' a ',
          '',
          'a',
          'b',
          'c',
          'd',
          'e',
          'f',
        ],
      });
      final history = RecentHermesModels();

      await history.recordSuccessfulSwitch('  ');

      expect(await history.load(), ['a', 'b', 'c', 'd', 'e']);
    },
  );

  test('does not lose a model when writes happen close together', () async {
    final history = RecentHermesModels();

    await Future.wait([
      history.recordSuccessfulSwitch('first'),
      history.recordSuccessfulSwitch('second'),
    ]);

    expect(await history.load(), ['second', 'first']);
  });
  test(
    'account histories do not inherit another user or global history',
    () async {
      SharedPreferences.setMockInitialValues({
        RecentHermesModels.storageKey: <String>['legacy-private'],
      });
      var account = 'a';
      final history = RecentHermesModels(accountScope: () async => account);
      await history.recordSuccessfulSwitch('a-private');
      account = 'b';
      expect(await history.load(), isEmpty);
      await history.recordSuccessfulSwitch('b-private');
      account = 'a';
      expect(await history.load(), ['a-private']);
    },
  );
  test(
    'a queued write retains the account captured before switching',
    () async {
      var account = 'a';
      final history = RecentHermesModels(accountScope: () async => account);
      final saving = history.recordSuccessfulSwitch('a-private');
      account = 'b';
      await saving;
      expect(await history.load(), isEmpty);
      account = 'a';
      expect(await history.load(), ['a-private']);
    },
  );
}
