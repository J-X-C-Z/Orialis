import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/features/chat/data/chat_drafts.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_composer_attachments.dart';
import 'package:orialis_mobile/pages/chat/chat_page.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' as chat;

const _waitLimit = Duration(seconds: 5);

final class _PickedFile extends PlatformFile {
  _PickedFile(this.file);

  final File file;
  int pathReads = 0;

  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  String get path {
    pathReads++;
    return file.path;
  }

  @override
  XFile get xFile => XFile(file.path);
  @override
  int lengthSync() => file.lengthSync();
  @override
  Future<int> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class _GatePicker extends FilePickerPlatform {
  final entered = Completer<void>();
  final result = Completer<List<PlatformFile>>();

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    entered.complete();
    return result.future;
  }
}

Future<void> _openFiles(WidgetTester tester, _GatePicker picker) async {
  await tester.tap(chat.iconAction('附件与快捷指令'));
  await tester.pumpAndSettle().timeout(_waitLimit);
  await tester.tap(find.text('选择文件'));
  await tester.pumpAndSettle().timeout(_waitLimit);
  expect(picker.entered.isCompleted, isTrue);
  expect(picker.result.isCompleted, isFalse);
}

AppConfig _config(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ChatPage)),
  listen: false,
).read(appConfigProvider);

Future<void> _setServerUrl(
  WidgetTester tester,
  AppConfig config,
  String url,
) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  // Draft futures were created in the fake zone; keep their consumers there.
  final transaction = config
      .setServerUrl(url)
      .then<void>(
        (_) {
          completed = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          completed = true;
        },
      );
  await tester.pumpAndSettle().timeout(_waitLimit);
  for (var attempt = 0; !completed && attempt < 500; attempt++) {
    // Native callbacks need real event-loop time; fake-clock pumps alone starve them.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!completed) fail('Server identity transaction did not complete: $url');
  await transaction;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<_PickedFile> _temporaryFile(WidgetTester tester) async {
  final root = (await tester.runAsync(
    () => Directory.systemTemp
        .createTemp('orialis-picker-identity-')
        .timeout(_waitLimit),
  ))!;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    paths,
    (call) async => switch (call.method) {
      'getApplicationSupportDirectory' ||
      'getTemporaryDirectory' ||
      'getApplicationDocumentsDirectory' => root.path,
      _ => throw UnsupportedError('Unexpected path lookup: ${call.method}'),
    },
  );
  addTearDown(() async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    await tester.runAsync(
      () => root.delete(recursive: true).timeout(_waitLimit),
    );
  });
  final file = (await tester.runAsync(
    () => File('${root.path}/old-server-notes.txt')
        .writeAsString(
          'Real local attachment selected before the picker gate resolves.',
        )
        .timeout(_waitLimit),
  ))!;
  return _PickedFile(file);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final previous = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = previous);
  });

  testWidgets('server identity commit discards a late file picker result', (
    tester,
  ) async {
    final selected = await _temporaryFile(tester);
    final picker = _GatePicker();
    FilePickerPlatform.instance = picker;
    final h = await chat.openChat(tester);
    try {
      final config = _config(tester);
      final previousServer = await config.serverUrl();
      await tester.enterText(find.byType(EditableText).last, '旧服务器的草稿');
      await _openFiles(tester, picker);

      await _setServerUrl(tester, config, 'https://picker-identity.invalid');
      await tester.pumpAndSettle().timeout(_waitLimit);
      expect(await config.serverUrl(), 'https://picker-identity.invalid');
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        isEmpty,
      );

      expect(
        picker.result.isCompleted,
        isFalse,
        reason:
            'The new identity must commit while the picker is still pending.',
      );
      picker.result.complete([selected]);
      await tester.pumpAndSettle().timeout(_waitLimit);
      expect(
        selected.pathReads,
        0,
        reason: 'An expired picker must be rejected before local file import starts.',
      );
      expect(find.byType(ChatComposerAttachments), findsNothing);
      expect(find.text(selected.name), findsNothing);

      // Navigating out flushes the current draft; reopening checks persistence too.
      await tester.tap(chat.iconAction('返回会话列表'));
      await tester.pumpAndSettle().timeout(_waitLimit);
      await tester.tap(find.text('离线会话').first);
      await tester.pumpAndSettle().timeout(_waitLimit);
      final current = await (await ChatDrafts.open(config)).loadState(h.id);
      expect(current.attachments, isEmpty);
      expect(current.text, isEmpty);
      expect(find.byType(ChatComposerAttachments), findsNothing);

      await _setServerUrl(tester, config, previousServer);
      await tester.pumpAndSettle().timeout(_waitLimit);
      final original = await (await ChatDrafts.open(config)).loadState(h.id);
      expect(original.text, '旧服务器的草稿');
      expect(original.attachments, isEmpty);
      expect(find.byType(ChatComposerAttachments), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      if (!picker.result.isCompleted) picker.result.complete([]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle().timeout(_waitLimit);
    }
  });

  testWidgets(
    'a current picker adds a real file and removal survives reopening',
    (tester) async {
      final selected = await _temporaryFile(tester);
      final picker = _GatePicker();
      FilePickerPlatform.instance = picker;
      final h = await chat.openChat(tester);
      try {
        final config = _config(tester);
        await _openFiles(tester, picker);
        picker.result.complete([selected]);
        for (var attempt = 0; attempt < 100; attempt++) {
          // Only yield for native file I/O in the real zone, then pump outside it.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (find.byType(ChatComposerAttachments).evaluate().isNotEmpty) break;
        }
        expect(
          find.byType(ChatComposerAttachments),
          findsOneWidget,
          reason: 'The current picker did not finish importing the local attachment.',
        );
        await tester.pumpAndSettle().timeout(_waitLimit);
        final strip = tester.widget<ChatComposerAttachments>(
          find.byType(ChatComposerAttachments),
        );
        expect(strip.attachments.single.name, selected.name);
        expect(strip.attachments.single.size, selected.lengthSync());
        expect(
          await tester.runAsync(
            () =>
                File(strip.attachments.single.localPath)
                    .readAsString()
                    .timeout(_waitLimit),
          ),
          await tester.runAsync(
            () => selected.file.readAsString().timeout(_waitLimit),
          ),
        );

        await tester.tap(chat.iconAction('返回会话列表'));
        await tester.pumpAndSettle().timeout(_waitLimit);
        final saved = await (await ChatDrafts.open(config)).loadState(h.id);
        expect(saved.attachments.single.name, selected.name);
        await tester.tap(find.text('离线会话').first);
        await tester.pumpAndSettle().timeout(_waitLimit);
        expect(find.byType(ChatComposerAttachments), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('chat-remove-attachment-0')),
        );
        await tester.pumpAndSettle().timeout(_waitLimit);
        expect(find.byType(ChatComposerAttachments), findsNothing);

        await tester.tap(chat.iconAction('返回会话列表'));
        await tester.pumpAndSettle().timeout(_waitLimit);
        await tester.tap(find.text('离线会话').first);
        await tester.pumpAndSettle().timeout(_waitLimit);
        final removed = await (await ChatDrafts.open(config)).loadState(h.id);
        expect(removed.attachments, isEmpty);
        expect(find.byType(ChatComposerAttachments), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!picker.result.isCompleted) picker.result.complete([]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle().timeout(_waitLimit);
      }
    },
  );
}
