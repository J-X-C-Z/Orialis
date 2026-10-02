import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Platform.environment['NEWS_NATIVE_OUTPUT'];
  if (output == null || output.isEmpty) {
    throw StateError('Set NEWS_NATIVE_OUTPUT to the owned evidence directory.');
  }
  await Directory(output).create(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      await File('$output/$name.png').writeAsBytes(bytes);
      return true;
    },
    responseDataCallback: (data) {
      final result = Map<String, dynamic>.from(data ?? const {});
      final screenshots = result.remove('screenshots');
      result['screenshotCount'] = screenshots is List ? screenshots.length : 0;
      return writeResponseData(
        result,
        destinationDirectory: output,
        testOutputFilename: 'integration-result',
      );
    },
    writeResponseOnFailure: true,
  );
}
