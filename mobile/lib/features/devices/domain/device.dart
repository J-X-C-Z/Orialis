class DeviceCapability {
  const DeviceCapability({
    required this.name,
    required this.available,
    required this.granted,
  });

  final String name;
  final bool available;
  final bool granted;

  factory DeviceCapability.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final version = json['version'];
    final available = json['available'];
    final risk = json['risk'];
    final constraints = json['constraints'];
    final grant = json['grant'];
    if (name is! String ||
        version is! String ||
        available is! bool ||
        !{'low', 'medium', 'high'}.contains(risk) ||
        constraints is! Map ||
        (grant != null &&
            !{'allow', 'deny', 'ask', 'unconfigured'}.contains(grant))) {
      throw const FormatException('invalid Node capability');
    }
    return DeviceCapability(
      name: name,
      available: available,
      granted: grant == 'allow',
    );
  }
}

class ConnectedDevice {
  const ConnectedDevice({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.status,
    required this.capabilities,
    this.isDefault = false,
    this.accountId,
    this.nodeVersion,
    this.lastSeenAt,
    this.observedAt,
    this.revocationVersion,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DeviceStatus status;
  final List<DeviceCapability> capabilities;
  final bool isDefault;
  final String? accountId;
  final String? nodeVersion;
  final DateTime? lastSeenAt;
  final DateTime? observedAt;
  final int? revocationVersion;

  ConnectedDevice copyWith({String? displayName, bool? isDefault}) =>
      ConnectedDevice(
        deviceId: deviceId,
        displayName: displayName ?? this.displayName,
        platform: platform,
        status: status,
        capabilities: capabilities,
        isDefault: isDefault ?? this.isDefault,
        accountId: accountId,
        nodeVersion: nodeVersion,
        lastSeenAt: lastSeenAt,
        observedAt: observedAt,
        revocationVersion: revocationVersion,
      );

  factory ConnectedDevice.fromJson(Map<String, dynamic> json) {
    final id = json['deviceId'];
    final accountId = json['accountId'];
    final statusValue = json['status'];
    final capabilitiesValue = json['capabilities'];
    final createdAt = json['createdAt'];
    final lastSeenAt = json['lastSeenAt'];
    final observedAt = json['observedAt'];
    final revocationVersion = json['revocationVersion'];
    if (json['protocolVersion'] != '1' ||
        id is! String ||
        id.isEmpty ||
        accountId is! String ||
        accountId.isEmpty ||
        statusValue is! String ||
        capabilitiesValue is! List ||
        createdAt is! String ||
        (lastSeenAt != null && lastSeenAt is! String) ||
        observedAt is! String ||
        revocationVersion is! int ||
        revocationVersion < 0) {
      throw const FormatException('invalid Node device response');
    }
    DateTime.parse(createdAt);
    if (lastSeenAt != null) DateTime.parse(lastSeenAt as String);
    DateTime.parse(observedAt);
    final capabilities = capabilitiesValue
        .map((value) {
          if (value is! Map) {
            throw const FormatException('invalid Node capability');
          }
          return DeviceCapability.fromJson(Map<String, dynamic>.from(value));
        })
        .toList(growable: false);
    return ConnectedDevice(
      deviceId: id,
      displayName: json['displayName'] as String? ?? id,
      platform: json['platform'] as String? ?? '未知平台',
      status: DeviceStatus.values.firstWhere(
        (value) => value.name == statusValue,
        orElse: () => throw const FormatException('invalid Node device status'),
      ),
      capabilities: capabilities,
      accountId: accountId,
      nodeVersion: json['nodeVersion'] as String?,
      lastSeenAt: lastSeenAt == null
          ? null
          : DateTime.parse(lastSeenAt as String),
      observedAt: DateTime.parse(observedAt),
      revocationVersion: revocationVersion,
    );
  }
}

enum DeviceStatus { online, offline, revoked, unknown }
