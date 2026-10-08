import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'news/news_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LuminaCardMemory.initialize();
  runApp(const ProviderScope(child: OrialisNewsApp()));
}
