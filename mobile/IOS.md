# Orialis iOS 1.5.1

此版本用于个人自签安装。最低 iOS 15.0，支持 iPhone 和 iPad，包标识为 `top.jxcz.orialis`，版本为 `1.5.1 (80)`。

## 个人安装

`Orialis-1.5.1-ios-self-sign.ipa` 使用标准 `Payload/Runner.app` 结构。请用自己的 Apple ID 重新签名后安装。

1. 在 Mac 上安装 [Sideloadly](https://sideloadly.io/index.html)，用 USB 连接并信任你的 iPhone。
2. 将 IPA 拖入 Sideloadly，选择手机，输入你自己的 Apple ID，执行签名安装。Apple ID 与验证信息只在工具中输入，不写入项目。
3. 如手机提示，按系统要求在「设置 → 隐私与安全」启用开发者模式，并在「通用 → VPN 与设备管理」信任相应开发者。

免费 Apple ID 签名通常有效 7 天，可使用工具的自动刷新；后续更新继续使用同一 Apple ID 和包标识以覆盖安装。[签名有效期与覆盖安装说明](https://sideloadly.io/faq)。本次没有可用的 Apple 签名身份或已连接 iPhone，尚未完成个人签名、安装和真机业务验收。

## 功能范围

复用手机端的任务、日程、项目、聊天、资讯、统一账号和云同步界面。iOS 云记忆复用现有本地账号隔离缓存，可接收云端记录和图片、编辑笔记并同步；这项平台接入有自动回归测试，真实 iPhone 跨设备同步仍待验收。

Android 的辅助截屏、快捷设置磁贴、外部分享接收、系统通知/日程跟踪、原生日历同步、小米手环原生连接及 APK 更新安装器没有移植到 iOS。iOS 不提供跨应用辅助截屏，也没有在后台长期运行 Android JobScheduler 分析任务；记忆同步在应用运行和恢复到前台时进行。聊天中的文件/照片附件和系统分享输出沿用现有跨平台插件。相册、相机权限只为用户主动选择的附件操作声明，未新增后台采集权限。

## 从源码构建

使用 Flutter 3.47.4、Xcode 27.2 和 CocoaPods。在 `mobile/` 下执行：

```sh
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
```

结果为 `build/ios/iphoneos/Runner.app`。无签名 `.app` 或 ZIP 不能直接安装到普通 iPhone。用于重签的 IPA 可将该目录放到 `Payload/Runner.app` 后压缩 `Payload` 文件夹生成；必须保留目录、可执行文件和框架。

也可以打开 `ios/Runner.xcworkspace`，在 Runner 的 Signing & Capabilities 中选择你自己的 Personal Team，连接自己的 iPhone 后由 Xcode 签名运行。当前工程保留钥匙串配置以保存会话，不包含团队标识、证书、设备配置文件或账号凭据。
