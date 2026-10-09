import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'core/config/app_config.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'news/news_data.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('Orialis desktop: loading preferences');
  await LuminaCardMemory.initialize();
  debugPrint('Orialis desktop: resolving account');
  final config = AppConfig(desktop: true);
  final databaseName = await config.desktopDatabaseName();
  debugPrint('Orialis desktop: starting UI');
  runApp(
    ProviderScope(
      overrides: [
        desktopModeProvider.overrideWithValue(true),
        appConfigProvider.overrideWithValue(config),
        newsConfigProvider.overrideWithValue(config),
        desktopDatabaseNameProvider.overrideWith((ref) => databaseName),
      ],
      child: const OrialisApp(),
    ),
  );
}
