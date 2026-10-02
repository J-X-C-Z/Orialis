import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../../../app/app.dart' show appConfigProvider;
import '../../../core/config/app_config.dart';

import '../data/device_data_source.dart';
import '../domain/device.dart';

const currentDeviceIdKey = 'orialis.currentDeviceId';

/// In-memory cache namespace helper. Device data must never share entries
/// between Node IDs, even while the account and screen remain the same.
class DeviceScopedCache<T> {
  final Map<String, T> _entries = {};
  T? read(String accountScope, String deviceId) =>
      _entries[_key(accountScope, deviceId)];
  void write(String accountScope, String deviceId, T value) =>
      _entries[_key(accountScope, deviceId)] = value;
  void remove(String accountScope, String deviceId) =>
      _entries.remove(_key(accountScope, deviceId));

  String _key(String accountScope, String deviceId) =>
      '$accountScope\u0000$deviceId';
}

final deviceDataSourceProvider = Provider<DeviceDataSource>((ref) {
  final source = NodeApiDeviceDataSource(config: ref.watch(appConfigProvider));
  ref.onDispose(source.dispose);
  return source;
});

class DeviceCenterState {
  const DeviceCenterState({
    this.devices = const [],
    this.currentDeviceId,
    this.loading = true,
    this.error,
    this.selectedDetails,
    this.pairingChallenge,
  });

  final List<ConnectedDevice> devices;
  final String? currentDeviceId;
  final bool loading;
  final String? error;
  final ConnectedDevice? selectedDetails;
  final PairingChallenge? pairingChallenge;

  DeviceCenterState copyWith({
    List<ConnectedDevice>? devices,
    String? currentDeviceId,
    bool clearCurrentDevice = false,
    bool? loading,
    String? error,
    bool clearError = false,
    ConnectedDevice? selectedDetails,
    bool clearSelectedDetails = false,
    PairingChallenge? pairingChallenge,
    bool clearPairingChallenge = false,
  }) => DeviceCenterState(
    devices: devices ?? this.devices,
    currentDeviceId: clearCurrentDevice
        ? null
        : currentDeviceId ?? this.currentDeviceId,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    selectedDetails: clearSelectedDetails
        ? null
        : selectedDetails ?? this.selectedDetails,
    pairingChallenge: clearPairingChallenge
        ? null
        : pairingChallenge ?? this.pairingChallenge,
  );
}

class DeviceCenterController extends StateNotifier<DeviceCenterState> {
  DeviceCenterController(this._source, {AppConfig? config})
    : _config = config,
      super(const DeviceCenterState()) {
    if (config != null && _source is NodeApiDeviceDataSource) {
      config.addIdentityListener(_onIdentityChange);
    }
    load();
  }

  final DeviceDataSource _source;
  final AppConfig? _config;
  int _identityGeneration = 0;
  int _loadGeneration = 0;
  int _detailsGeneration = 0;
  bool _disposed = false;

  PairingChallenge? get activePairingChallenge => state.pairingChallenge;

  Future<void> _onIdentityChange() async {
    if (_disposed) return;
    _identityGeneration++;
    _loadGeneration++;
    _detailsGeneration++;
    state = const DeviceCenterState(loading: true);
    Future<void>.delayed(Duration.zero, () {
      if (!_disposed) load();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _config?.removeIdentityListener(_onIdentityChange);
    super.dispose();
  }

  Future<void> load() async {
    final generation = _identityGeneration;
    final loadGeneration = ++_loadGeneration;
    _detailsGeneration++;
    try {
      final devices = await _source.listDevices();
      if (_disposed ||
          generation != _identityGeneration ||
          loadGeneration != _loadGeneration) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final saved = _source is NodeApiDeviceDataSource
          ? prefs.getString(await _source.currentDevicePreferenceKey())
          : prefs.getString(currentDeviceIdKey);
      if (_disposed ||
          generation != _identityGeneration ||
          loadGeneration != _loadGeneration) {
        return;
      }
      final selected = devices.any((d) => d.deviceId == saved)
          ? saved
          : _firstWhereOrNull(devices, (d) => d.isDefault)?.deviceId ??
                (devices.isEmpty ? null : devices.first.deviceId);
      state = state.copyWith(
        devices: devices,
        currentDeviceId: selected,
        clearCurrentDevice: selected == null,
        clearSelectedDetails: selected != state.currentDeviceId,
        loading: false,
        clearError: true,
      );
      if (selected != null && selected != saved) {
        if (_source is NodeApiDeviceDataSource) {
          await prefs.setString(
            await _source.currentDevicePreferenceKey(),
            selected,
          );
        } else {
          await prefs.setString(currentDeviceIdKey, selected);
        }
      }
      if (_disposed ||
          generation != _identityGeneration ||
          loadGeneration != _loadGeneration) {
        return;
      }
      if (selected != null) await loadDetails(selected);
    } catch (error) {
      if (_disposed ||
          generation != _identityGeneration ||
          loadGeneration != _loadGeneration) {
        return;
      }
      state = state.copyWith(
        loading: false,
        error: deviceCenterException(error).message,
        devices: const [],
        clearCurrentDevice: true,
      );
    }
  }

  Future<void> select(String deviceId) async {
    if (!state.devices.any((d) => d.deviceId == deviceId)) return;
    final generation = _identityGeneration;
    _loadGeneration++;
    _detailsGeneration++;
    // Selection changes the view/cache namespace; callers key device-scoped
    // results with this ID and must discard the previous selection's state.
    final prefs = await SharedPreferences.getInstance();
    final prefKey = _source is NodeApiDeviceDataSource
        ? await _source.currentDevicePreferenceKey()
        : currentDeviceIdKey;
    if (_disposed || generation != _identityGeneration) return;
    await prefs.setString(prefKey, deviceId);
    state = state.copyWith(
      currentDeviceId: deviceId,
      clearSelectedDetails: true,
      clearError: true,
    );
    await loadDetails(deviceId);
  }

  Future<void> loadDetails(String deviceId) async {
    final generation = _identityGeneration;
    final detailsGeneration = ++_detailsGeneration;
    try {
      final detail = await _source.getDevice(deviceId);
      final capabilities = await _source.getCapabilities(deviceId);
      if (_disposed ||
          generation != _identityGeneration ||
          detailsGeneration != _detailsGeneration ||
          state.currentDeviceId != deviceId) {
        return;
      }
      state = state.copyWith(
        selectedDetails: ConnectedDevice(
          deviceId: detail.deviceId,
          displayName: detail.displayName,
          platform: detail.platform,
          status: detail.status,
          capabilities: capabilities,
          accountId: detail.accountId,
          nodeVersion: detail.nodeVersion,
          lastSeenAt: detail.lastSeenAt,
          observedAt: detail.observedAt,
          revocationVersion: detail.revocationVersion,
        ),
        clearError: true,
      );
    } catch (error) {
      if (_disposed ||
          generation != _identityGeneration ||
          detailsGeneration != _detailsGeneration ||
          state.currentDeviceId != deviceId) {
        return;
      }
      state = state.copyWith(error: deviceCenterException(error).message);
    }
  }

  Future<void> revoke(String deviceId) async {
    final generation = _identityGeneration;
    final wasSelected = state.currentDeviceId == deviceId;
    if (wasSelected) {
      _loadGeneration++;
      _detailsGeneration++;
      state = state.copyWith(clearSelectedDetails: true);
    }
    await _source.revoke(deviceId);
    if (_disposed || generation != _identityGeneration) return;
    if (wasSelected) {
      final prefs = await SharedPreferences.getInstance();
      final prefKey = _source is NodeApiDeviceDataSource
          ? await _source.currentDevicePreferenceKey()
          : currentDeviceIdKey;
      if (_disposed || generation != _identityGeneration) return;
      await prefs.remove(prefKey);
      state = state.copyWith(
        clearCurrentDevice: true,
        clearSelectedDetails: true,
      );
    }
    await load();
  }

  Future<void> confirmPairing(String pairingId, String confirmationCode) async {
    await _source.confirmPairing(pairingId, confirmationCode);
  }

  Future<void> rejectPairing(String pairingId, String confirmationCode) async {
    await _source.rejectPairing(pairingId, confirmationCode);
  }

  Future<void> startPairing(String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) throw const DeviceCenterException('请输入本机设备名称');
    final identity = NodeIdentity(
      displayName: name,
      platform: defaultTargetPlatform.name,
      nodeVersion: '0.1.0',
    );
    final challenge = await _source.startPairing(identity);
    if (_disposed) return;
    state = state.copyWith(pairingChallenge: challenge, clearError: true);
  }

  Future<void> completePairing() async {
    final challenge = state.pairingChallenge;
    if (challenge == null) throw const DeviceCenterException('没有待完成的配对');
    final deviceId = await _source.completePairing(challenge);
    if (_disposed) return;
    state = state.copyWith(clearPairingChallenge: true);
    await load();
    if (_disposed) return;
    if (state.devices.any((device) => device.deviceId == deviceId)) {
      await select(deviceId);
    }
  }
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}

final deviceCenterControllerProvider =
    StateNotifierProvider<DeviceCenterController, DeviceCenterState>(
      (ref) => DeviceCenterController(
        ref.watch(deviceDataSourceProvider),
        config: ref.watch(appConfigProvider),
      ),
    );
