import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../core/database/legacy_database_reader.dart';

final legacyDatabaseFileProvider = FutureProvider<File?>((ref) async {
  if (ref.watch(desktopModeProvider)) return null;
  final directory = await ref.watch(databaseDirectoryProvider)();
  final file = File('${directory.path}/orialis.sqlite');
  return await file.exists() ? file : null;
});

const legacyRecoveryMessage =
    '发现旧版本地数据，尚未确认所属账户。旧文件和待同步内容已保留，'
    '不会上传到当前账户。请在“我的 → 旧版数据（只读）”查看。';

class LegacyRecoveryNotice extends ConsumerWidget {
  const LegacyRecoveryNotice({super.key, this.allowOpen = false});
  final bool allowOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(legacyDatabaseFileProvider);
    return result.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const Padding(
        padding: EdgeInsets.all(12),
        child: Text('旧版本地数据检查失败，请稍后重试；原文件未删除。'),
      ),
      data: (file) => file == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(legacyRecoveryMessage),
                  if (allowOpen)
                    TextButton(
                      child: const Text('旧版数据（只读）'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => LegacyRecoveryPage(file: file),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class LegacyRecoveryPage extends StatefulWidget {
  const LegacyRecoveryPage({super.key, required this.file});
  final File file;
  @override
  State<LegacyRecoveryPage> createState() => _LegacyRecoveryPageState();
}

class _LegacyRecoveryPageState extends State<LegacyRecoveryPage> {
  late final reader = LegacyDatabaseReader(widget.file);
  late final available = reader.availableTables();
  String? selected;
  int offset = 0;
  Future<List<Map<String, Object?>>>? page;

  void select(String table, int nextOffset) => setState(() {
    selected = table;
    offset = nextOffset;
    page = reader.readPage(table, offset);
  });

  @override
  void dispose() {
    reader.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('旧版数据（只读）')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('未确认账户归属，仅供查看和手动找回内容。此入口不能编辑、同步、复制到当前账户或删除旧数据。'),
        ),
        FutureBuilder<List<String>>(
          future: available,
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Text('旧库无法读取，原文件仍保留。');
            if (!snapshot.hasData) return const LinearProgressIndicator();
            return DropdownButton<String>(
              hint: const Text('选择内容类型（包含待同步记录）'),
              value: selected,
              items: snapshot.data!
                  .map(
                    (table) =>
                        DropdownMenuItem(value: table, child: Text(table)),
                  )
                  .toList(),
              onChanged: (table) {
                if (table != null) select(table, 0);
              },
            );
          },
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: page,
            builder: (context, snapshot) {
              if (snapshot.hasError) return const Text('这页无法读取，旧数据未修改。');
              if (!snapshot.hasData) return const Text('请选择内容类型');
              return ListView(
                children: snapshot.data!
                    .map(
                      (row) => Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(row),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
        if (selected != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: offset == 0
                    ? null
                    : () => select(selected!, offset - 100),
                child: const Text('上一页'),
              ),
              Text('${offset ~/ 100 + 1}'),
              TextButton(
                onPressed: () => select(selected!, offset + 100),
                child: const Text('下一页'),
              ),
            ],
          ),
      ],
    ),
  );
}
