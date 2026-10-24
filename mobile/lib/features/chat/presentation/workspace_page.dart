import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:xterm/xterm.dart';

import '../../../app/design/lumina_compat.dart' show OrialisPageScaffold;
import '../data/workspace_client.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({required this.client, super.key});
  final WorkspaceClient client;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  List<Map<String, dynamic>> _workspaces = [], _entries = [];
  Set<String> _operations = {};
  String? _workspaceId, _error, _preview, _terminalId;
  String _path = '', _previewTitle = '';
  bool _busy = false, _terminalVisible = false, _closed = false;
  final _terminal = Terminal(maxLines: 3000);
  Timer? _poll;
  Future<void> _inputQueue = Future.value();

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (input) {
      // Keystrokes must reach the PTY in order even on a slow connection.
      _inputQueue = _inputQueue.then((_) => _writeTerminal(input));
    };
    _terminal.onResize = (width, height, _, _) {
      final id = _terminalId;
      if (id != null) {
        unawaited(
          _terminalRequest('terminal.resize', {
            'terminalId': id,
            'columns': width.clamp(20, 300),
            'rows': height.clamp(5, 120),
          }),
        );
      }
    };
    unawaited(_load());
  }

  Map<String, dynamic> _scope([Map<String, dynamic> values = const {}]) => {
    'workspaceId': _workspaceId,
    ...values,
  };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _closed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    if (_terminalId != null) {
      await _closeTerminal();
      if (!mounted || _closed) return;
      _terminalVisible = false;
      _error = null;
    }
    final data = await widget.client.request('capabilities');
    if (!mounted) return;
    _workspaces = (data['workspaces'] as List? ?? [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    _operations = (data['operations'] as List? ?? [])
        .whereType<String>()
        .toSet();
    _workspaceId = _workspaces.firstOrNull?['id'] as String?;
    if (_workspaceId != null) await _list('');
  });

  Future<void> _list(String path) async {
    final data = await widget.client.request('list', _scope({'path': path}));
    if (!mounted) return;
    setState(() {
      _path = path;
      _preview = null;
      _entries = (data['entries'] as List? ?? [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
    });
  }

  Future<void> _openFile(Map<String, dynamic> entry) => _run(() async {
    if (entry['isDirectory'] == true) {
      await _list(entry['path'] as String);
      return;
    }
    final data = await widget.client.request(
      'read',
      _scope({'path': entry['path']}),
    );
    if (!mounted) return;
    setState(() {
      _previewTitle = entry['path'] as String;
      _preview = data['text'] as String? ?? '';
    });
  });

  Future<void> _diff() => _run(() async {
    final data = await widget.client.request('diff', _scope());
    if (!mounted) return;
    setState(() {
      _previewTitle = '代码变更';
      _terminalVisible = false;
      _preview = data['text'] as String? ?? '';
      if (_preview!.isEmpty) _preview = '没有未提交的代码变更。';
    });
  });

  Future<void> _upload() => _run(() async {
    final file = await FilePicker.pickFile();
    if (file == null || !mounted || _closed) return;
    final size = await file.length();
    if (size == null) throw StateError('无法读取文件大小，请重新选择文件');
    if (size > 1024 * 1024) throw StateError('工作区文件传输上限为 1 MiB');
    final bytes = await file.readAsBytes();
    if (bytes.length > 1024 * 1024) throw StateError('工作区文件传输上限为 1 MiB');
    if (!mounted || _closed) return;
    await widget.client.request(
      'upload',
      _scope({
        'path': _path.isEmpty ? file.name : '$_path/${file.name}',
        'base64': base64Encode(bytes),
      }),
    );
    await _list(_path);
  });

  Future<void> _download([String? filePath]) => _run(() async {
    final pathToDownload = filePath ?? _previewTitle;
    final data = await widget.client.request(
      'download',
      _scope({'path': pathToDownload}),
    );
    if (!mounted || _closed) return;
    final bytes = base64Decode(data['base64'] as String);
    await FilePicker.saveFile(
      dialogTitle: '保存工作区文件',
      fileName: pathToDownload.split('/').last,
      bytes: bytes,
    );
  });

  Future<void> _startTerminal() => _run(() async {
    final data = await widget.client.request(
      'terminal.open',
      _scope({
        'columns': _terminal.viewWidth.clamp(20, 300),
        'rows': _terminal.viewHeight.clamp(5, 120),
      }),
    );
    final id = data['terminalId'] as String;
    if (!mounted || _closed) {
      await widget.client.request('terminal.close', _scope({'terminalId': id}));
      return;
    }
    setState(() {
      _terminalId = id;
      _terminalVisible = true;
    });
    _schedulePoll();
  });

  Future<void> _writeTerminal(String input) async {
    final id = _terminalId;
    if (id == null || _closed) return;
    await _terminalRequest('terminal.write', {
      'terminalId': id,
      'input': input,
    });
  }

  Future<void> _terminalRequest(
    String op,
    Map<String, dynamic> arguments,
  ) async {
    try {
      await widget.client.request(op, _scope(arguments));
    } catch (error) {
      if (mounted && !_closed) {
        _poll?.cancel();
        setState(() => _error = '$error');
      }
    }
  }

  void _schedulePoll() {
    _poll = Timer(const Duration(milliseconds: 300), () async {
      final id = _terminalId;
      if (id == null || _closed) return;
      try {
        final data = await widget.client.request(
          'terminal.read',
          _scope({'terminalId': id}),
        );
        if (!mounted || _closed || _terminalId != id) return;
        _terminal.write(data['output'] as String? ?? '');
        if (data['truncated'] == true) _terminal.write('\r\n[部分输出已截断]\r\n');
        if (data['exited'] == true) {
          _terminal.write('\r\n[终端已结束：${data['exitCode'] ?? ''}]\r\n');
          await _closeTerminal();
        } else {
          _schedulePoll();
        }
      } catch (error) {
        if (mounted && !_closed) setState(() => _error = '$error');
      }
    });
  }

  Future<void> _closeTerminal() async {
    _poll?.cancel();
    final id = _terminalId;
    _terminalId = null;
    if (mounted) setState(() {});
    if (id != null) {
      await _terminalRequest('terminal.close', {'terminalId': id});
    }
  }

  Future<void> _leave() async {
    if (_closed) return;
    _closed = true;
    await _closeTerminal();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closed = true;
    _poll?.cancel();
    // The host also expires idle/disconnected PTYs; the normal back path closes immediately.
    final id = _terminalId;
    if (id != null) {
      unawaited(
        widget.client
            .request('terminal.close', _scope({'terminalId': id}))
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    widget.client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _closed,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_leave());
    },
    child: OrialisPageScaffold(
      title: '工作区',
      subtitle: '文件、代码变更与终端',
      leading: LuminaIconButton(
        icon: const LuminaIcon(LuminaIcons.back),
        tooltip: '返回聊天',
        onPressed: _leave,
      ),
      body: Builder(
        builder: (context) => LuminaMaterialBridge(
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.only(
                top: LuminaPageHeaderInset.of(context) + 12,
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: _busy ? null : _load,
                            child: const Text('重新连接'),
                          ),
                        ],
                      ),
                    ),
                  if (_workspaces.isNotEmpty) ...[
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _workspaceId,
                      items: [
                        for (final workspace in _workspaces)
                          DropdownMenuItem(
                            value: workspace['id'] as String,
                            child: Text(workspace['name'] as String? ?? '工作区'),
                          ),
                      ],
                      onChanged: _busy || _terminalId != null
                          ? null
                          : (id) {
                              setState(() {
                                _workspaceId = id;
                                _terminalVisible = false;
                              });
                              unawaited(_run(() => _list('')));
                            },
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () =>
                                setState(() => _terminalVisible = false),
                            child: const Text('文件'),
                          ),
                          if (_operations.contains('diff'))
                            TextButton(
                              onPressed: _busy ? null : _diff,
                              child: const Text('代码变更'),
                            ),
                          if (_operations.contains('upload'))
                            TextButton(
                              onPressed: _busy ? null : _upload,
                              child: const Text('上传文件'),
                            ),
                          if (_terminalId != null)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _terminalVisible = true),
                              child: const Text('终端'),
                            )
                          else if (_workspaces
                                  .where((w) => w['id'] == _workspaceId)
                                  .firstOrNull?['terminalEnabled'] ==
                              true)
                            TextButton(
                              onPressed: _busy ? null : _startTerminal,
                              child: const Text('打开终端'),
                            ),
                        ],
                      ),
                    ),
                  ],
                  Expanded(
                    child: _terminalVisible ? _terminalBody() : _fileBody(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _terminalBody() => Column(
    children: [
      Row(
        children: [
          TextButton(
            onPressed: () => _writeTerminal('\x03'),
            child: const Text('Ctrl+C'),
          ),
          TextButton(
            onPressed: () => _writeTerminal('\t'),
            child: const Text('Tab'),
          ),
          TextButton(
            onPressed: () => _writeTerminal('\x1b[A'),
            child: const Text('↑'),
          ),
          TextButton(
            onPressed: () => _writeTerminal('\x1b[B'),
            child: const Text('↓'),
          ),
          const Spacer(),
          TextButton(onPressed: _closeTerminal, child: const Text('关闭')),
        ],
      ),
      Expanded(child: TerminalView(_terminal, autofocus: true)),
    ],
  );

  Widget _fileBody() {
    if (_workspaces.isEmpty && !_busy) {
      return const Center(child: Text('此设备尚未开放工作区。\n请在 Hermes 设备配置允许访问的项目目录。'));
    }
    if (_preview != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: () => setState(() => _preview = null),
                child: const Text('返回文件列表'),
              ),
              if (_previewTitle != '代码变更')
                TextButton(
                  onPressed: _busy ? null : _download,
                  child: const Text('下载'),
                ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _preview!));
                  if (mounted) showLuminaToast(context, '已复制');
                },
                child: const Text('复制'),
              ),
            ],
          ),
          Text(_previewTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                _preview!,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (_path.isNotEmpty)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => _list(
                          _path
                              .split('/')
                              .take(_path.split('/').length - 1)
                              .join('/'),
                        ),
                      ),
                child: const Text('上一级'),
              ),
            Expanded(
              child: Text(
                _path.isEmpty ? '/' : _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: '刷新目录',
              onPressed: _busy ? null : () => _run(() => _list(_path)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return LuminaListRow(
                title: entry['name'] as String? ?? '',
                subtitle: entry['isDirectory'] == true
                    ? '文件夹'
                    : '${entry['size'] ?? 0} 字节',
                leading: LuminaIcon(
                  entry['isDirectory'] == true
                      ? LuminaIcons.folder
                      : LuminaIcons.file,
                ),
                trailing:
                    entry['isDirectory'] != true &&
                        _operations.contains('download')
                    ? TextButton(
                        onPressed: _busy
                            ? null
                            : () => _download(entry['path'] as String),
                        child: const Text('下载'),
                      )
                    : null,
                onTap: _busy ? null : () => _openFile(entry),
              );
            },
          ),
        ),
      ],
    );
  }
}
