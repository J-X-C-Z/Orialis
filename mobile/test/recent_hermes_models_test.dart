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
}
