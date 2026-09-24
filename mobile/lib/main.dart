import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/design/design_components.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LuminaCardMemory.initialize();
  runApp(const ProviderScope(child: OrialisApp()));
}
