<<<<<<< HEAD
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'link_sync.dart';
import 'server_client.dart';
import 'wristband_contract.dart';

const _ink = Color(0xFF101719);
const _panel = Color(0xFF182326);
const _teal = Color(0xFF8DEBDF);
const _muted = Color(0xFFA7BCB8);

String defaultServerUrl() {
  return 'https://schedule.woxingsf.top';
}
=======
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _ink = Color(0xFF0D1217);
const _panel = Color(0xFF151E25);
const _teal = Color(0xFF8DEBDF);
const _amber = Color(0xFFFFC978);
const _text = Color(0xFFE8F5F1);
const _muted = Color(0xFF9AB5B1);
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

void main() => runApp(const FangcunDevToolsApp());

class FangcunDevToolsApp extends StatelessWidget {
  const FangcunDevToolsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _teal,
      brightness: Brightness.dark,
      surface: _panel,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
<<<<<<< HEAD
      title: '方寸',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: scheme.copyWith(primary: _teal, secondary: _teal),
        scaffoldBackgroundColor: _ink,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _panel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withAlpha(18)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _teal),
          ),
        ),
        useMaterial3: true,
      ),
      home: const FangcunHomePage(),
=======
      title: '方寸开发者模式',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: scheme.copyWith(primary: _teal, secondary: _amber),
        scaffoldBackgroundColor: _ink,
        useMaterial3: true,
      ),
      home: const DeveloperConsolePage(),
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    );
  }
}

<<<<<<< HEAD
class FangcunHomePage extends StatefulWidget {
  const FangcunHomePage({super.key});

  @override
  State<FangcunHomePage> createState() => _FangcunHomePageState();
}

class _FangcunHomePageState extends State<FangcunHomePage> with WidgetsBindingObserver {
  final _serverController = TextEditingController(text: defaultServerUrl());
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  FangcunServerClient? _client;
  Map<String, dynamic> _document = <String, dynamic>{};
  Map<String, dynamic> _user = <String, dynamic>{};
  int _revision = 0;
  String? _updatedAt;
  String? _message;
  bool _busy = false;
  bool _showWebView = false;
  String _webViewStatus = '未打开';
  WebViewController? _webViewController;
  final _wristband = WristbandClient();
  WristbandCapabilities? _wristbandStatus;
  String? _wristbandMessage;
  bool _wristbandBusy = false;
  int? _lastWristbandRevision;
  Timer? _autoSyncTimer;
  bool _syncInFlight = false;
  int _activeMenu = 0;
  DateTime _calendarDate = DateTime.now();

  bool get _signedIn => _client?.isAuthenticated == true;

  static const _sessionUrlKey = 'fangcun.session.url';
  static const _sessionTokenKey = 'fangcun.session.token';
  static const _backgroundSyncChannel = MethodChannel('app.fangcun/hyperos');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startAutoSync();
      _syncToWristband(automatic: true);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _autoSyncTimer?.cancel();
      _autoSyncTimer = null;
    }
  }

  void _startAutoSync() {
    if (!_signedIn || _autoSyncTimer != null) return;
    _autoSyncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _syncToWristband(automatic: true);
    });
  }

  Future<void> _restoreSession() async {
    Map<String, String> stored;
    try {
      stored = await _secureStorage.readAll();
    } catch (_) {
      // Secure storage is unavailable in widget tests and on unsupported hosts.
      return;
    }
    final url = stored[_sessionUrlKey];
    final token = stored[_sessionTokenKey];
    if (url == null || token == null || token.isEmpty) return;
    final baseUrl = Uri.tryParse(url);
    if (baseUrl == null || baseUrl.host.isEmpty) {
      await _clearStoredSession();
      return;
    }
    _serverController.text = url;
    if (mounted) setState(() { _busy = true; _message = '正在恢复登录…'; });
    final client = FangcunServerClient(baseUrl: baseUrl)..restoreSession(token);
    try {
      final session = await client.session();
      if (session['authenticated'] != true) {
        await _clearStoredSession();
        if (mounted) setState(() { _busy = false; _message = '登录已失效，请重新登录'; });
        return;
      }
      final remote = await client.getData();
      if (!mounted) return;
      setState(() {
        _client = client;
        _user = session['user'] is Map ? Map<String, dynamic>.from(session['user'] as Map) : <String, dynamic>{};
        _setRemote(remote);
        _busy = false;
        _message = '已恢复登录';
      });
      await _saveSession(client, baseUrl);
      await _refreshWristbandStatus(silent: true);
      _startAutoSync();
      await _syncToWristband(automatic: true);
    } on FangcunApiException catch (error) {
      if (error.statusCode == 401) await _clearStoredSession();
      if (mounted) setState(() { _busy = false; _message = _errorMessage(error); });
    } catch (error) {
      if (mounted) setState(() { _busy = false; _message = _errorMessage(error); });
    }
  }

  Future<void> _saveSession(FangcunServerClient client, Uri baseUrl) async {
    final token = client.accessToken;
    if (token == null) return;
    await _secureStorage.write(key: _sessionUrlKey, value: baseUrl.toString());
    await _secureStorage.write(key: _sessionTokenKey, value: token);
    try {
      await _backgroundSyncChannel.invokeMethod('configureBackgroundSync', {
        'serverUrl': baseUrl.toString(),
        'token': token,
      });
    } on MissingPluginException {
      // Desktop/widget-test hosts do not have the Android worker.
    }
  }

  Future<void> _clearStoredSession() async {
    await _secureStorage.delete(key: _sessionUrlKey);
    await _secureStorage.delete(key: _sessionTokenKey);
    try {
      await _backgroundSyncChannel.invokeMethod('clearBackgroundSync');
    } on MissingPluginException {
      // Desktop/widget-test hosts do not have the Android worker.
    }
  }

  void _ensureWebViewController() {
    if (_webViewController != null) return;
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => mounted ? setState(() => _webViewStatus = '加载中') : null,
        onPageFinished: (_) => mounted ? setState(() => _webViewStatus = '已连接') : null,
        onWebResourceError: (_) => mounted ? setState(() => _webViewStatus = '页面加载失败') : null,
      ))
      ..loadRequest(Uri.parse(defaultServerUrl()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSyncTimer?.cancel();
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final baseUrl = Uri.tryParse(_serverController.text.trim());
    if (baseUrl == null ||
        !['http', 'https'].contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty) {
      setState(() => _message = '请输入有效的 Rust Server 地址');
      return;
    }
    if (_usernameController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _message = '请输入用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _message = '正在连接 Rust Server…';
    });
    final client = FangcunServerClient(baseUrl: baseUrl);
    try {
      final session = await client.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );
      final remote = await client.getData();
      if (!mounted) return;
      setState(() {
        _client = client;
        _user = session.user;
        _setRemote(remote);
        _message = '已连接 Rust Server';
        _busy = false;
      });
      await _saveSession(client, baseUrl);
      await _refreshWristbandStatus(silent: true);
      _startAutoSync();
      await _syncToWristband(automatic: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _errorMessage(error);
      });
    }
  }

  Future<void> _refresh() async {
    final client = _client;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    if (client == null) return;
    setState(() {
      _busy = true;
      _message = '正在读取最新数据…';
    });
    try {
      final remote = await client.getData();
      if (!mounted) return;
      setState(() {
        _setRemote(remote);
        _message = '数据已刷新';
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _errorMessage(error);
      });
    }
  }

  Future<void> _toggleTask(int index, bool completed) async {
    final client = _client;
    if (client == null) return;
    final tasks = _tasks
        .map((task) => Map<String, dynamic>.from(task))
        .toList();
    if (index >= tasks.length) return;
    tasks[index]['completed'] = completed;
    tasks[index]['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    final next = _copyDocument()..['tasks'] = tasks;
    setState(() {
      _document = next;
      _message = completed ? '已在本地标记完成，正在写入服务器…' : '正在恢复任务…';
    });
    try {
      final result = await client.putData(next, _revision);
      if (!mounted) return;
      setState(() {
        _revision = result.revision;
        _updatedAt = result.updatedAt;
        _message = '已同步到 Rust Server · revision $_revision';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _errorMessage(error));
      if (error is RevisionConflictException) await _refresh();
    }
  }

  Future<void> _addTask() async {
    final title = await showDialog<String>(
      context: context,
      builder: (context) => const _AddTaskDialog(),
    );
    if (!mounted || title == null || title.trim().isEmpty) return;
    final client = _client;
    if (client == null) return;
    final tasks = _tasks
        .map((task) => Map<String, dynamic>.from(task))
        .toList();
    final timestamp = DateTime.now().toUtc().toIso8601String();
    tasks.insert(0, {
      'id': 'flutter-${DateTime.now().microsecondsSinceEpoch}',
      'title': title.trim(),
      'completed': false,
      'important': false,
      'urgent': false,
      'createdAt': timestamp,
      'updatedAt': timestamp,
    });
    final next = _copyDocument()..['tasks'] = tasks;
    setState(() {
      _busy = true;
      _document = next;
      _message = '正在创建任务…';
    });
    try {
      final result = await client.putData(next, _revision);
      if (!mounted) return;
      setState(() {
        _revision = result.revision;
        _updatedAt = result.updatedAt;
        _busy = false;
        _message = '任务已创建并同步';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _errorMessage(error);
      });
      if (error is RevisionConflictException) await _refresh();
    }
  }

  Future<void> _logout() async {
    final client = _client;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    await _clearStoredSession();
    if (client != null) {
      try { await client.logout(); } catch (_) { /* Local sign-out is still complete. */ }
    }
    if (!mounted) return;
    setState(() {
      _client = null;
      _document = <String, dynamic>{};
      _user = <String, dynamic>{};
      _revision = 0;
      _updatedAt = null;
      _message = '已退出登录';
    });
  }

  Future<void> _refreshWristbandStatus({bool silent = false}) async {
    if (!silent && mounted) setState(() => _wristbandBusy = true);
    try {
      final status = await _wristband.status();
      if (!mounted) return;
      setState(() {
        _wristbandStatus = status;
        _wristbandBusy = false;
        if (!silent) _wristbandMessage = status.lastError ?? '手环状态已刷新';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _wristbandBusy = false;
        _wristbandMessage = '无法读取手环状态：$error';
      });
    }
  }

  Future<void> _connectWristband() async {
    setState(() {
      _wristbandBusy = true;
      _wristbandMessage = '正在发现并连接手环…';
    });
    try {
      final result = await _wristband.connect();
      final status = await _wristband.status();
      if (!mounted) return;
      setState(() {
        _wristbandStatus = status;
        _wristbandBusy = false;
        _wristbandMessage = result.ok
            ? '手环已连接${status.nodeName == null ? '' : '：${status.nodeName}'}'
            : '连接失败：${result.error ?? '未发现可用手环'}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _wristbandBusy = false;
        _wristbandMessage = '连接失败：$error';
      });
    }
  }

  Future<void> _syncToWristband({bool automatic = false}) async {
    final client = _client;
    if (client == null || _syncInFlight) return;
    _syncInFlight = true;
    if (!automatic && mounted) {
      setState(() {
        _wristbandBusy = true;
        _wristbandMessage = '正在读取服务器快照并发送至手环…';
      });
    }
    try {
      final remote = await client.getData();
      if (mounted) _setRemote(remote);
      final synced = await LinkSyncCoordinator(server: client, wristband: _wristband)
          .syncBidirectional(lastRevision: _lastWristbandRevision);
      if (synced.appliedEvents > 0) {
        _setRemote(await client.getData());
      }
      final status = await _wristband.status();
      if (!mounted) return;
      setState(() {
        _wristbandStatus = status;
        _wristbandBusy = false;
        if (automatic) return;
        if (synced.result.skipped) {
          _wristbandMessage = synced.appliedEvents > 0
              ? '已回传 ${synced.appliedEvents} 项手环操作 · 手环已是最新版本'
              : '手环已是最新版本 · 数据版本 ${synced.result.snapshot.revision}';
        } else if (synced.result.wristband?.ok == true) {
          _lastWristbandRevision = synced.result.snapshot.revision;
          _wristbandMessage = synced.appliedEvents > 0
              ? '已回传 ${synced.appliedEvents} 项手环操作并完成同步 · 数据版本 ${synced.result.snapshot.revision}'
              : '已收到手环确认 · 数据版本 ${synced.result.snapshot.revision}';
        } else {
          _wristbandMessage = '同步失败：${synced.result.wristband?.error ?? '手环未确认'}';
        }
      });
    } catch (error) {
      if (automatic) return;
      if (!mounted) return;
      setState(() {
        _wristbandBusy = false;
        _wristbandMessage = '同步失败：${_errorMessage(error)}';
      });
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _openWristbandApp() async {
    setState(() {
      _wristbandBusy = true;
      _wristbandMessage = '正在打开手环端方寸…';
    });
    try {
      final result = await _wristband.openApp();
      final status = await _wristband.status();
      if (!mounted) return;
      setState(() {
        _wristbandStatus = status;
        _wristbandBusy = false;
        _wristbandMessage = result.ok
            ? '已向手环发送打开方寸的请求'
            : '无法打开手环端方寸：${result.error ?? '未连接'}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _wristbandBusy = false;
        _wristbandMessage = '无法打开手环端方寸：$error';
      });
    }
  }

  Future<void> _openDebugPanel() async {
    final client = _client;
    JsonObject? health;
    String? healthError;
    if (client != null) {
      try {
        health = await client.publicHealth();
      } catch (error) {
        healthError = _errorMessage(error);
      }
    }
    if (!mounted) return;
    final native = await const MethodChannel('app.fangcun/hyperos')
        .invokeMethod<dynamic>('getCapabilities')
        .catchError((_) => <String, dynamic>{'state': 'unavailable'});
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _DebugPanel(
        serverUrl: _serverController.text.trim(),
        health: health,
        healthError: healthError,
        native: native is Map ? Map<String, dynamic>.from(native) : <String, dynamic>{},
        showWebView: _showWebView,
        onModeChanged: (value) {
          Navigator.of(context).pop();
          if (value) _ensureWebViewController();
          setState(() => _showWebView = value);
        },
      ),
    );
  }

  void _setRemote(DataSnapshot remote) {
    final raw = remote.data;
    _document = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    if (_document['tasks'] is! List) _document['tasks'] = <dynamic>[];
    _revision = remote.revision;
    _updatedAt = remote.updatedAt;
  }

  Map<String, dynamic> _copyDocument() => Map<String, dynamic>.from(_document);

  List<Map<String, dynamic>> get _tasks {
    final raw = _document['tasks'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((task) => Map<String, dynamic>.from(task))
        .toList();
  }

  List<Map<String, dynamic>> get _projects {
    final raw = _document['projects'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }

  List<Map<String, dynamic>> get _courses {
    final raw = _document['courses'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime date) =>
      '${date.month}月${date.day}日 · ${['一', '二', '三', '四', '五', '六', '日'][date.weekday - 1]}';

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  List<Map<String, dynamic>> _tasksForDate(DateTime date) {
    final key = _dateKey(date);
    return _tasks.where((task) {
      final due = task['due']?.toString();
      final start = task['startDate']?.toString();
      return due == key || start == key || (_isToday(date) && task['today'] == true);
    }).toList();
  }

  Future<void> _toggleMilestone(String projectId, int index, bool completed) async {
    final client = _client;
    if (client == null) return;
    final projects = _projects;
    final projectIndex = projects.indexWhere((item) => item['id']?.toString() == projectId);
    if (projectIndex < 0) return;
    final milestones = (projects[projectIndex]['milestones'] as List? ?? const [])
        .whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    if (index >= milestones.length) return;
    milestones[index]['completed'] = completed;
    projects[projectIndex]['milestones'] = milestones;
    final next = _copyDocument()..['projects'] = projects;
    setState(() { _document = next; _busy = true; _message = '正在更新项目节点…'; });
    try {
      final result = await client.putData(next, _revision);
      if (!mounted) return;
      setState(() { _revision = result.revision; _updatedAt = result.updatedAt; _busy = false; _message = '项目节点已更新'; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _busy = false; _message = _errorMessage(error); });
      if (error is RevisionConflictException) await _refresh();
    }
  }

  Future<void> _addProject() async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const _AddProjectDialog(),
    );
    final client = _client;
    if (!mounted || client == null || values == null || values['name']!.trim().isEmpty) return;
    final projects = _projects;
    final id = 'flutter-project-${DateTime.now().microsecondsSinceEpoch}';
    projects.insert(0, {
      'id': id,
      'name': values['name']!.trim(),
      'goal': values['goal']!.trim(),
      'startDate': _dateKey(DateTime.now()),
      'due': values['due'] ?? '',
      'milestones': <Map<String, dynamic>>[],
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    final next = _copyDocument()..['projects'] = projects;
    setState(() { _document = next; _busy = true; _message = '正在创建长期项目…'; });
    try {
      final result = await client.putData(next, _revision);
      if (!mounted) return;
      setState(() { _revision = result.revision; _updatedAt = result.updatedAt; _busy = false; _message = '长期项目已创建'; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _busy = false; _message = _errorMessage(error); });
      if (error is RevisionConflictException) await _refresh();
    }
  }

  String _errorMessage(Object error) {
    if (error is FangcunApiException) return error.message;
    if (error is SocketException) return '无法连接 Rust Server：${error.message}';
    return '请求失败：$error';
=======
class NativeEventClient {
  static const _channel = MethodChannel('app.fangcun/hyperos');

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? arguments]) async {
    try {
      final result = await _channel.invokeMethod<dynamic>(method, arguments);
      if (result is Map) {
        return Map<String, dynamic>.from(
          result.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      // Widget tests and a host without a registered handler can both return
      // null. Treat that the same as a missing native module.
      return {'ok': false, 'simulated': true, 'message': 'Native Module 尚未嵌入，当前为 Flutter 模拟回显'};
    } on MissingPluginException {
      return {'ok': false, 'simulated': true, 'message': 'Native Module 尚未嵌入，当前为 Flutter 模拟回显'};
    } catch (error) {
      return {'ok': false, 'message': error.toString()};
    }
  }
}

class EventSpec {
  const EventSpec(this.event, this.label, this.icon, this.color);

  final String event;
  final String label;
  final IconData icon;
  final Color color;
}

const _eventSpecs = [
  EventSpec('focus.start', 'Focus 开始', Icons.play_arrow_rounded, _teal),
  EventSpec('focus.pause', 'Focus 暂停', Icons.pause_rounded, _amber),
  EventSpec('focus.complete', 'Focus 完成', Icons.check_rounded, Color(0xFF9FE6A0)),
  EventSpec('course.start', '课程开始', Icons.school_rounded, Color(0xFFA8C7FF)),
  EventSpec('ddl.remind', 'DDL 提醒', Icons.notifications_active_rounded, Color(0xFFFF9F9F)),
];

class DeveloperConsolePage extends StatefulWidget {
  const DeveloperConsolePage({super.key});

  @override
  State<DeveloperConsolePage> createState() => _DeveloperConsolePageState();
}

class _DeveloperConsolePageState extends State<DeveloperConsolePage> {
  final _native = NativeEventClient();
  final _history = <String>[];
  EventSpec _active = _eventSpecs.first;
  String _status = '等待触发';
  Map<String, dynamic> _capabilities = const {};
  bool _expanded = true;
  Offset _dragOffset = Offset.zero;
  bool _busy = false;

  Future<void> _trigger(EventSpec spec) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _active = spec;
      _status = '正在发送 ${spec.event}';
    });
    final result = await _native.call('triggerEvent', {
      'event': spec.event,
      'payload': {
        'title': spec.event.startsWith('focus') ? 'C++训练' : spec.event == 'course.start' ? '大学物理实验' : '实验报告',
        'progress': '43 / 60 min',
        'time': '14:30 - 16:30',
        'due': '今天 23:59',
      },
    });
    if (!mounted) return;
    final simulated = result['simulated'] == true;
    setState(() {
      _busy = false;
      _status = simulated ? 'Flutter 模拟回显 · ${spec.event}' : 'Native Module 已响应 · ${spec.event}';
      _history.insert(0, '${_time()}  ${spec.event}');
      if (_history.length > 6) _history.removeLast();
    });
  }

  Future<void> _loadCapabilities() async {
    final result = await _native.call('getCapabilities');
    if (!mounted) return;
    setState(() {
      _capabilities = result;
      _status = result['simulated'] == true ? '能力检测处于模拟模式' : '设备能力已读取';
    });
  }

  Future<void> _playHaptic(String semantic) async {
    await _native.call('haptic', {'semantic': semantic});
    if (!mounted) return;
    setState(() {
      _status = '触感 · $semantic';
      _history.insert(0, '${_time()}  haptic.$semantic');
      if (_history.length > 6) _history.removeLast();
    });
  }

  String _time() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
<<<<<<< HEAD
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _showWebView ? _buildWebViewPage() : (_signedIn ? _buildAppPage() : _buildLoginPage()),
        ),
      ),
      floatingActionButton: _signedIn && _activeMenu != 4
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _addTask,
              icon: const Icon(Icons.add),
              label: const Text('新任务'),
            )
      : null,
    );
  }

  Widget _buildAppPage() {
    final titles = const ['今天', '优先级', '日历', '长期项目', '设置'];
    final icons = const [Icons.today_outlined, Icons.grid_view, Icons.calendar_month_outlined, Icons.diamond_outlined, Icons.settings_outlined];
    return Column(
      key: const ValueKey('app'),
      children: [
        Expanded(child: switch (_activeMenu) {
          0 => _buildTodayPage(),
          1 => _buildPriorityPage(),
          2 => _buildCalendarPage(),
          3 => _buildProjectsPage(),
          _ => _buildSettingsPage(),
        }),
        NavigationBar(
          selectedIndex: _activeMenu,
          onDestinationSelected: (index) => setState(() => _activeMenu = index),
          destinations: [
            for (var index = 0; index < titles.length; index++)
              NavigationDestination(icon: Icon(icons[index]), label: titles[index]),
          ],
        ),
      ],
    );
  }

  Widget _pageScaffold({required String title, required Widget child, List<Widget> actions = const []}) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(title),
            actions: [
              IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
              ...actions,
            ],
          ),
          SliverPadding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 28), sliver: SliverToBoxAdapter(child: child)),
        ],
      ),
    );
  }

  Widget _buildTodayPage() {
    final tasks = _tasksForDate(DateTime.now());
    final pending = tasks.where((task) => task['completed'] != true).length;
    return _pageScaffold(
      title: '今天',
      actions: [IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: '退出登录')],
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('今天', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text('${_displayDate(DateTime.now())} · $pending 项待完成', style: TextStyle(color: _muted.withAlpha(220))),
        const SizedBox(height: 16),
        if (_message != null) _StatusLine(message: _message!, busy: _busy),
        if (tasks.isEmpty)
          const _EmptyTasks()
        else
          ...tasks.map((task) {
            final index = _tasks.indexWhere((item) => item['id'] == task['id']);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TaskTile(task: task, completed: task['completed'] == true, onChanged: _busy ? null : (value) => _toggleTask(index, value ?? false)),
            );
          }),
      ]),
    );
  }

  Widget _buildPriorityPage() {
    final groups = <String, List<Map<String, dynamic>>>{
      '重要且紧急': _tasks.where((task) => task['important'] == true && task['urgent'] == true || task['quadrant'] == 'q1').toList(),
      '重要不紧急': _tasks.where((task) => task['important'] == true && task['urgent'] != true || task['quadrant'] == 'q2').toList(),
      '紧急不重要': _tasks.where((task) => task['important'] != true && task['urgent'] == true || task['quadrant'] == 'q3').toList(),
      '暂不安排': _tasks.where((task) => task['quadrant'] == 'q4' || (task['important'] != true && task['urgent'] != true && task['quadrant'] == null)).toList(),
    };
    return _pageScaffold(title: '优先级', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('按重要程度查看全部任务'),
      const SizedBox(height: 12),
      for (final entry in groups.entries) ...[
        Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (entry.value.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 14), child: Text('暂无任务')),
        ...entry.value.map((task) {
          final index = _tasks.indexWhere((item) => item['id'] == task['id']);
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: _TaskTile(task: task, completed: task['completed'] == true, onChanged: _busy ? null : (value) => _toggleTask(index, value ?? false)));
        }),
        const SizedBox(height: 8),
      ],
    ]));
  }

  Widget _buildCalendarPage() {
    final tasks = _tasksForDate(_calendarDate);
    final courses = _courses.where((course) => course['date']?.toString() == _dateKey(_calendarDate) || course['startDate']?.toString() == _dateKey(_calendarDate) || course['day'] == _calendarDate.weekday).toList();
    return _pageScaffold(title: '日历', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(onPressed: () => setState(() => _calendarDate = _calendarDate.subtract(const Duration(days: 1))), icon: const Icon(Icons.chevron_left)),
        Expanded(child: Center(child: Text(_displayDate(_calendarDate), style: const TextStyle(fontWeight: FontWeight.w700)))),
        IconButton(onPressed: () => setState(() => _calendarDate = _calendarDate.add(const Duration(days: 1))), icon: const Icon(Icons.chevron_right)),
        TextButton(onPressed: () => setState(() => _calendarDate = DateTime.now()), child: const Text('今天')),
      ]),
      const Divider(),
      if (courses.isEmpty && tasks.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('这一天没有安排'))),
      ...courses.map((course) => _ScheduleTile(title: course['name']?.toString() ?? course['title']?.toString() ?? '课程', detail: '${course['startTime'] ?? (course['startSection'] == null ? '' : '第${course['startSection']}节')} ${course['location'] ?? ''}')),
      ...tasks.map((task) => _ScheduleTile(title: task['title']?.toString() ?? '任务', detail: task['dueTime']?.toString() ?? '任务')),
    ]));
  }

  Widget _buildProjectsPage() {
    return _pageScaffold(title: '长期项目', actions: [IconButton(onPressed: _addProject, icon: const Icon(Icons.add), tooltip: '新建项目')], child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_projects.length} 个项目', style: TextStyle(color: _muted.withAlpha(220))),
      const SizedBox(height: 12),
      if (_projects.isEmpty) const _EmptyProjects(onAdd: null),
      ..._projects.map((project) {
        final milestones = (project['milestones'] as List? ?? const []).whereType<Map>().toList();
        final done = milestones.where((item) => item['completed'] == true).length;
        final actions = _tasks.where((task) => task['projectId']?.toString() == project['id']?.toString() && task['completed'] != true).take(3).toList();
        return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(project['name']?.toString() ?? '未命名项目', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if ((project['goal']?.toString() ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(project['goal'].toString())),
          const SizedBox(height: 10),
          Text('里程碑 $done/${milestones.length}'),
          for (var index = 0; index < milestones.length; index++) CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, value: milestones[index]['completed'] == true, title: Text(milestones[index]['title']?.toString() ?? '节点'), onChanged: _busy ? null : (value) => _toggleMilestone(project['id'].toString(), index, value ?? false)),
          if (actions.isNotEmpty) ...[const Divider(), const Text('下一步', style: TextStyle(fontWeight: FontWeight.w600)), ...actions.map((task) => ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(task['title']?.toString() ?? '任务')))],
        ])));
      }),
    ]));
  }

  Widget _buildSettingsPage() {
    final name = _user['displayName'] ?? _user['username'] ?? '方寸用户';
    return _pageScaffold(title: '设置', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.person_outline), title: Text(name.toString()), subtitle: Text(_serverController.text)),
      const Divider(),
      ListTile(leading: const Icon(Icons.sync), title: const Text('立即同步'), subtitle: Text(_message ?? '读取服务器并同步手环'), onTap: _busy ? null : () => _syncToWristband()),
      ListTile(leading: const Icon(Icons.watch_outlined), title: const Text('手环连接'), subtitle: Text(_wristbandMessage ?? '检测手环状态'), onTap: _wristbandBusy ? null : _refreshWristbandStatus),
      ListTile(leading: const Icon(Icons.developer_mode), title: const Text('开发者设置'), onTap: _openDebugPanel),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _busy ? null : _logout, icon: const Icon(Icons.logout), label: const Text('退出登录')),
    ]));
  }

  Widget _buildLoginPage() {
    return Center(
      key: const ValueKey('login'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerRight, child: IconButton(onPressed: _openDebugPanel, icon: const Icon(Icons.developer_mode), tooltip: '开发者设置')),
              const Icon(Icons.stars_rounded, color: _teal, size: 48),
              const SizedBox(height: 16),
              const Text(
                '方寸',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Flutter 最小客户端',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted.withAlpha(220)),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _serverController,
                decoration: const InputDecoration(
                  labelText: 'Rust Server 地址',
                  hintText: 'https://schedule.woxingsf.top',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: '用户名'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: '密码'),
                obscureText: true,
                onSubmitted: (_) => _busy ? null : _login(),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _login,
                icon: const Icon(Icons.login),
                label: Text(_busy ? '连接中…' : '登录并读取数据'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                _StatusLine(message: _message!, busy: _busy),
              ],
              const SizedBox(height: 18),
              Text(
                '开发版默认连接线上 Rust Server。可在开发者设置中切换原方寸 WebView。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _muted.withAlpha(180),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebViewPage() {
    return Column(
      key: const ValueKey('webview'),
      children: [
        Material(
          color: _panel,
          child: SafeArea(
            bottom: false,
            child: Row(children: [
              IconButton(onPressed: () => setState(() => _showWebView = false), icon: const Icon(Icons.arrow_back)),
              const Expanded(child: Text('方寸 WebView', style: TextStyle(fontWeight: FontWeight.w700))),
              Text(_webViewStatus, style: TextStyle(color: _muted.withAlpha(210), fontSize: 12)),
              IconButton(onPressed: () => _webViewController?.reload(), icon: const Icon(Icons.refresh)),
            ]),
          ),
        ),
        Expanded(
          child: _webViewController == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _webViewController!),
        ),
      ],
    );
  }

  // Kept as a fallback reference for the previous single-page layout.
  // ignore: unused_element
  Widget _buildTasksPage() {
    final pending = _tasks.where((task) => task['completed'] != true).length;
    final name = _user['displayName'] ?? _user['username'] ?? '方寸用户';
    final updatedLabel = _updatedAt == null
        ? 'Rust Server 数据'
        : '服务器更新：$_updatedAt';
    return RefreshIndicator(
      key: const ValueKey('tasks'),
      onRefresh: _refresh,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '你好，$name',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '今天先完成最重要的一件事。',
                          style: TextStyle(color: _muted.withAlpha(220)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _refresh,
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _logout,
                    tooltip: '退出',
                    icon: const Icon(Icons.logout),
                  ),
                  IconButton(onPressed: _openDebugPanel, icon: const Icon(Icons.developer_mode), tooltip: '开发者设置'),
                  IconButton(onPressed: _wristbandBusy ? null : _refreshWristbandStatus, icon: const Icon(Icons.watch_outlined), tooltip: '手环状态'),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: '待完成',
                      value: '$pending',
                      icon: Icons.radio_button_unchecked,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricCard(
                      label: '版本',
                      value: '$_revision',
                      icon: Icons.cloud_done_outlined,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_message != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              sliver: SliverToBoxAdapter(
                child: _StatusLine(message: _message!, busy: _busy),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                updatedLabel,
                style: TextStyle(color: _muted.withAlpha(180), fontSize: 11),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            sliver: SliverToBoxAdapter(
              child: _WristbandCard(
                status: _wristbandStatus,
                message: _wristbandMessage,
                busy: _wristbandBusy,
                onRefresh: _refreshWristbandStatus,
                onConnect: _connectWristband,
                onOpen: _openWristbandApp,
                onSync: _syncToWristband,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 120),
            sliver: _tasks.isEmpty
                ? SliverToBoxAdapter(child: _EmptyTasks(onAdd: _addTask))
                : SliverList.separated(
                    itemCount: _tasks.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final task = _tasks[index];
                      final completed = task['completed'] == true;
                      return _TaskTile(
                        task: task,
                        completed: completed,
                        onChanged: _busy
                            ? null
                            : (value) => _toggleTask(index, value ?? false),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    color: _panel,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: _teal),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                style: TextStyle(color: _muted.withAlpha(210), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _WristbandCard extends StatelessWidget {
  const _WristbandCard({
    required this.status,
    required this.message,
    required this.busy,
    required this.onRefresh,
    required this.onConnect,
    required this.onOpen,
    required this.onSync,
  });

  final WristbandCapabilities? status;
  final String? message;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onConnect;
  final VoidCallback onOpen;
  final VoidCallback onSync;

  String get _stateLabel => switch (status?.state) {
    WristbandState.connected => '已连接',
    WristbandState.connecting => '连接中',
    WristbandState.disconnected => '未连接',
    WristbandState.error => '连接异常',
    _ => '等待检测',
  };

  @override
  Widget build(BuildContext context) {
    final connected = status?.state == WristbandState.connected;
    final available = status?.available == true;
    final detail = message ??
        status?.lastError ??
        (status == null
            ? '登录后自动检测。请确认手环已安装方寸应用并与小米穿戴连接。'
            : status!.nodeName ?? status!.adapter);
    final pendingEvents = (status?.raw['pendingEventCount'] as num?)?.toInt() ?? 0;
    final diagnostics = status == null
        ? null
        : '节点 ${status!.nodeCount} · 穿戴服务 ${status!.serviceConnection ?? '未知'}'
          '${pendingEvents > 0 ? ' · 待回传 $pendingEvents 项' : ''}';
    return Card(
      color: _panel,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.watch_outlined, color: _teal),
              const SizedBox(width: 10),
              const Expanded(child: Text('手环互联', style: TextStyle(fontWeight: FontWeight.w700))),
              if (busy)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Text(_stateLabel, style: TextStyle(color: connected ? _teal : _muted, fontSize: 12)),
            ]),
            const SizedBox(height: 10),
            Text(detail, style: TextStyle(color: _muted.withAlpha(220), fontSize: 12, height: 1.4)),
            if (diagnostics != null) ...[
              const SizedBox(height: 4),
              Text(diagnostics, style: TextStyle(color: _muted.withAlpha(170), fontSize: 11)),
            ],
            if (status?.requiresPermissions.isNotEmpty == true) ...[
              const SizedBox(height: 5),
              Text('需要权限：${status!.requiresPermissions.join('、')}', style: TextStyle(color: _muted.withAlpha(170), fontSize: 11)),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('检测'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: busy || !available || connected ? null : onConnect,
                icon: const Icon(Icons.link),
                label: const Text('连接手环'),
              ),
              FilledButton.icon(
                onPressed: busy || !connected ? null : onOpen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('打开手环方寸'),
              ),
              FilledButton.icon(
                onPressed: busy || !connected ? null : onSync,
                icon: const Icon(Icons.sync),
                label: const Text('同步'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _DebugPanel extends StatelessWidget {
  const _DebugPanel({
    required this.serverUrl,
    required this.health,
    required this.healthError,
    required this.native,
    required this.showWebView,
    required this.onModeChanged,
  });

  final String serverUrl;
  final JsonObject? health;
  final String? healthError;
  final Map<String, dynamic> native;
  final bool showWebView;
  final ValueChanged<bool> onModeChanged;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('开发者设置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Flutter'), icon: Icon(Icons.flutter_dash)),
              ButtonSegment(value: true, label: Text('原方寸 WebView'), icon: Icon(Icons.web)),
            ],
            selected: {showWebView},
            onSelectionChanged: (value) => onModeChanged(value.first),
          ),
          const SizedBox(height: 16),
          _DebugValue(label: '服务地址', value: serverUrl),
          _DebugValue(label: '服务状态', value: healthError ?? (health?['ok'] == true ? '在线' : '未知')),
          if (health != null) _DebugValue(label: '服务版本', value: '${health!['version'] ?? '-'}'),
          _DebugValue(label: '原生手环通道', value: native['methodChannelReady'] == true ? '已注册' : '不可用'),
          _DebugValue(label: '设备', value: '${native['manufacturer'] ?? '-'} ${native['model'] ?? ''}'),
          const SizedBox(height: 8),
          Text('WebView 保留原方寸网页与手环连接路径；Flutter 使用同一服务器数据与原生 MethodChannel。', style: TextStyle(color: _muted.withAlpha(210), fontSize: 12, height: 1.45)),
        ],
      ),
    ),
  );
}

class _DebugValue extends StatelessWidget {
  const _DebugValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      SizedBox(width: 92, child: Text(label, style: TextStyle(color: _muted.withAlpha(190), fontSize: 12))),
      Expanded(child: Text(value, overflow: TextOverflow.ellipsis)),
    ]),
  );
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.completed,
    required this.onChanged,
  });
  final Map<String, dynamic> task;
  final bool completed;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final title = task['title']?.toString().trim();
    final due = task['due']?.toString().trim();
    return Card(
      color: _panel,
      child: CheckboxListTile(
        value: completed,
        onChanged: onChanged,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          title == null || title.isEmpty ? '未命名任务' : title,
          style: TextStyle(
            decoration: completed ? TextDecoration.lineThrough : null,
            color: completed ? _muted : null,
          ),
        ),
        subtitle: due == null || due.isEmpty ? null : Text(due),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.busy});
  final String message;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      if (busy) ...[
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: _teal),
        ),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted.withAlpha(220), fontSize: 12),
        ),
      ),
    ],
  );
}

class _EmptyTasks extends StatelessWidget {
  const _EmptyTasks({this.onAdd});
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Card(
    color: _panel,
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(Icons.inbox_outlined, color: _teal, size: 36),
          const SizedBox(height: 12),
          const Text('服务器还没有任务'),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('创建第一项'),
          ),
        ],
      ),
    ),
  );
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects({this.onAdd});
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(children: [
        const Icon(Icons.diamond_outlined, color: _teal, size: 36),
        const SizedBox(height: 12),
        const Text('还没有长期项目'),
        if (onAdd != null) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('新建项目')),
        ],
      ]),
    ),
  );
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(leading: const Icon(Icons.event_note_outlined), title: Text(title), subtitle: detail.trim().isEmpty ? null : Text(detail)),
  );
}

class _AddProjectDialog extends StatefulWidget {
  const _AddProjectDialog();

  @override
  State<_AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<_AddProjectDialog> {
  final name = TextEditingController();
  final goal = TextEditingController();
  final due = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    goal.dispose();
    due.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建长期项目'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: '项目名称')),
      TextField(controller: goal, decoration: const InputDecoration(labelText: '目标（可选）')),
      TextField(controller: due, decoration: const InputDecoration(labelText: '目标日期 YYYY-MM-DD（可选）')),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.of(context).pop({'name': name.text, 'goal': goal.text, 'due': due.text}), child: const Text('创建')),
    ],
  );
}

class _AddTaskDialog extends StatefulWidget {
  const _AddTaskDialog();

  @override
  State<_AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<_AddTaskDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新任务'),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: '任务名称'),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(controller.text),
        child: const Text('创建'),
      ),
    ],
  );
=======
      body: Stack(
        children: [
          const Positioned.fill(child: CustomPaint(painter: _GridPainter())),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 170),
              child: _buildStage(context),
            ),
          ),
          _buildFloatingConsole(context),
        ],
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('方寸 / 实验台', style: TextStyle(color: _teal.withValues(alpha: .8), fontSize: 12, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  const Text('原生事件预览', style: TextStyle(color: _text, fontSize: 30, fontWeight: FontWeight.w700, height: 1.05)),
                  const SizedBox(height: 8),
                  Text('为超级岛、小部件和触感准备的可控现场。', style: TextStyle(color: _muted.withValues(alpha: .9), fontSize: 14)),
                ],
              ),
            ),
            _statusPill('DEBUG', _amber),
          ],
        ),
        const SizedBox(height: 28),
        _buildIslandStage(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _metric('通道', 'app.fangcun/hyperos', Icons.account_tree_rounded)),
            const SizedBox(width: 10),
            Expanded(child: _metric('事件', _active.event, Icons.bolt_rounded)),
          ],
        ),
        const SizedBox(height: 16),
        _buildCapabilities(),
      ],
    );
  }

  Widget _buildIslandStage() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _panel.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _teal.withValues(alpha: .12)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .24), blurRadius: 24, offset: const Offset(0, 14))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.waves_rounded, color: _teal.withValues(alpha: .85), size: 17),
              const SizedBox(width: 7),
              Text('SUPER ISLAND / FALLBACK PREVIEW', style: TextStyle(color: _muted, fontSize: 10, letterSpacing: 1.1)),
            ],
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            child: _islandCapsule(key: ValueKey(_active.event)),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: Text(_status, style: TextStyle(color: _active.color, fontSize: 12))),
              if (_busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _teal)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _islandCapsule({required Key key}) {
    final focus = _active.event.startsWith('focus');
    final title = focus ? 'C++训练' : _active.event == 'course.start' ? '大学物理实验' : '实验报告';
    final subtitle = focus ? '43 / 60 min' : _active.event == 'course.start' ? '14:30 - 16:30  ·  剩余 47 分钟' : '今天 23:59';
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: _active.color.withValues(alpha: .5)),
        boxShadow: [BoxShadow(color: _active.color.withValues(alpha: .12), blurRadius: 18)],
      ),
      child: Row(
        children: [
          Container(
            width: 35,
            height: 35,
            decoration: BoxDecoration(color: _active.color.withValues(alpha: .14), shape: BoxShape.circle),
            child: Icon(_active.icon, color: _active.color, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 15)), const SizedBox(height: 3), Text(subtitle, style: TextStyle(color: _muted, fontSize: 12))])),
          if (focus) SizedBox(width: 38, height: 38, child: CircularProgressIndicator(value: .72, strokeWidth: 3, color: _active.color, backgroundColor: _active.color.withValues(alpha: .14))),
        ],
      ),
    );
  }

  Widget _buildCapabilities() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _panel.withValues(alpha: .68), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withValues(alpha: .06))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Expanded(child: Text('设备能力', style: TextStyle(color: _text, fontWeight: FontWeight.w700))), TextButton(onPressed: _loadCapabilities, child: const Text('读取'))]),
        Text(_capabilities.isEmpty ? '尚未读取；点击右下角面板中的“能力检测”。' : _capabilities.toString(), style: TextStyle(color: _muted, fontSize: 11, height: 1.45)),
      ]),
    );
  }

  Widget _buildFloatingConsole(BuildContext context) {
    if (!_expanded) {
      return Positioned(
        right: 18 - _dragOffset.dx,
        bottom: 24 - _dragOffset.dy,
        child: GestureDetector(
          onPanUpdate: (details) => setState(() => _dragOffset += details.delta),
          child: _devBubble(),
        ),
      );
    }
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Transform.translate(offset: _dragOffset, child: _consolePanel()),
    );
  }

  Widget _devBubble() {
    return Container(
      width: 62,
      height: 52,
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(19), border: Border.all(color: _teal.withValues(alpha: .4)), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .3), blurRadius: 20)]),
      child: InkWell(onTap: () => setState(() => _expanded = true), borderRadius: BorderRadius.circular(19), child: const Center(child: Text('DEV', style: TextStyle(color: _teal, fontWeight: FontWeight.w800, letterSpacing: 1.2)))),
    );
  }

  Widget _consolePanel() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 430),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
      decoration: BoxDecoration(color: _panel.withValues(alpha: .98), borderRadius: BorderRadius.circular(25), border: Border.all(color: _teal.withValues(alpha: .22)), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .42), blurRadius: 30, offset: const Offset(0, 12))]),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(
            onPanUpdate: (details) => setState(() => _dragOffset += details.delta),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: _amber, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Expanded(child: Text('开发者模式', style: TextStyle(color: _text, fontWeight: FontWeight.w800, fontSize: 16))),
              TextButton(onPressed: () => setState(() => _expanded = false), child: const Text('收起')),
            ]),
          ),
          Text('主动触发原生事件 · 拖动标题移动悬浮窗', style: TextStyle(color: _muted, fontSize: 11)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: _eventSpecs.map(_eventButton).toList()),
          const SizedBox(height: 14),
          Text('语义触感', style: TextStyle(color: _muted, fontSize: 11)),
          const SizedBox(height: 7),
          Wrap(spacing: 7, children: ['light', 'snap', 'confirm', 'success'].map((semantic) => _smallAction(semantic, () => _playHaptic(semantic))).toList()),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: _smallAction('能力检测', _loadCapabilities)), const SizedBox(width: 8), Expanded(child: _smallAction('清除预览', () async { await _native.call('clearEvent'); if (mounted) setState(() => _status = '预览已清除'); }))]),
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_history.join('\n'), style: TextStyle(color: _muted, fontSize: 10, height: 1.55)),
          ],
        ]),
      ),
    );
  }

  Widget _eventButton(EventSpec spec) {
    return SizedBox(
      height: 38,
      child: FilledButton.tonalIcon(
        onPressed: () => _trigger(spec),
        icon: Icon(spec.icon, size: 16),
        label: Text(spec.label, style: const TextStyle(fontSize: 11)),
        style: FilledButton.styleFrom(foregroundColor: spec.color, backgroundColor: spec.color.withValues(alpha: .11), padding: const EdgeInsets.symmetric(horizontal: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    );
  }

  Widget _smallAction(String label, VoidCallback action) {
    return SizedBox(height: 34, child: OutlinedButton(onPressed: action, style: OutlinedButton.styleFrom(foregroundColor: _muted, side: BorderSide(color: Colors.white.withValues(alpha: .12)), padding: const EdgeInsets.symmetric(horizontal: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))), child: Text(label, style: const TextStyle(fontSize: 11))));
  }

  Widget _metric(String title, String value, IconData icon) => Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: _panel.withValues(alpha: .68), borderRadius: BorderRadius.circular(17)), child: Row(children: [Icon(icon, color: _teal.withValues(alpha: .75), size: 17), const SizedBox(width: 9), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: _muted, fontSize: 10)), const SizedBox(height: 3), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _text, fontSize: 11, fontWeight: FontWeight.w600))]))]));

  Widget _statusPill(String text, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: .3))), child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1)));
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: .025)..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 32) { canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint); }
    for (double y = 0; y < size.height; y += 32) { canvas.drawLine(Offset(0, y), Offset(size.width, y), paint); }
    final glow = Paint()..shader = RadialGradient(colors: [_teal.withValues(alpha: .09), Colors.transparent]).createShader(Rect.fromCircle(center: Offset(size.width * .78, size.height * .16), radius: size.width * .72));
    canvas.drawCircle(Offset(size.width * .78, size.height * .16), size.width * .72, glow);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}
