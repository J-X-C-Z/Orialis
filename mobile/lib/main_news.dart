import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/design/lumina_compat.dart';
import 'news/news_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LuminaCardMemory.initialize();
  runApp(const ProviderScope(child: OrialisNewsApp()));
}
