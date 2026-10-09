import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LuminaCardMemory.initialize();
  final config = AppConfig();
  final overrides = await mobileStartupOverrides(config);
  runApp(ProviderScope(overrides: overrides, child: const OrialisApp()));
}
