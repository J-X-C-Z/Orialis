# Xiaomi Wearable SDK 1.4

`xms-wearable-lib_1.4_release.aar` is the vendor SDK distributed with the
[official Vela interconnect demo](https://cdn.cnbj3-fusion.fds.api.mi-img.com/quickapp-vela/interconnect_dev_test_demo.zip),
linked from [Xiaomi's interconnect documentation](https://iot.mi.com/vela/quickapp/zh/features/network/interconnect.html).

Verified 2026-10-02: the existing Fangcun copy and both SDK copies in that official
download have identical bytes. Archive member: `interconnect_dev_test_demo/libs/xms-wearable-lib_1.4_release.aar`.

- Size: 102453 bytes
- SHA-256: `9c40fd1c5409bb948523d503af71e2978ae522c35636afe7d64f474c0f6bc195`
- SDK manifest: minSdk 19, targetSdk 30; package visibility includes
  `com.xiaomi.wearable` and `com.mi.health`.

Actual class signatures take precedence over outdated PDF examples:
`sendMessage(String, byte[])` returns `Task<Void>`, and `removeListener(String)`
takes only the node ID. `DEVICE_MANAGER` permits messaging; `NOTIFY` is for
system notifications and is not requested for Orialis snapshot transfer.

The SDK is not proof of device compatibility. APK and RPK must use the same
application ID and signing certificate, Mi Fitness must have a connected node,
and Orialis requires a matching application ACK before claiming delivery.
No signing keys are included here.
