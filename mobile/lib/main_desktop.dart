import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'core/config/app_config.dart';
import 'app/design/design_components.dart';
import 'news/news_data.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LuminaCardMemory.initialize();
  final config = AppConfig(desktop: true);
  final databaseName = await config.desktopDatabaseName();
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
