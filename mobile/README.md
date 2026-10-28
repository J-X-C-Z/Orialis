# Orialis 客户端构建

普通 Android 用户可直接从 [GitHub Releases](https://github.com/J-X-C-Z/Orialis/releases/latest) 下载安装包。本页用于自行构建 Android、macOS 或 Windows 客户端；自托管服务端和接入助手见 [部署指南](../docs/deployment.md)。

Android 和桌面端共享任务、项目、日历、聊天、本机数据库与同步代码。桌面端使用独立启动入口和侧栏布局，共用 `packages/lumina_ui` 的设计组件。

## 准备环境

- Flutter **3.47.0+**，包含 Dart **3.13.0+**；以 [pubspec.yaml](pubspec.yaml) 的约束为准。
- 构建 Android：Android SDK（项目 compileSdk 36）与 JDK 17。
- 构建 macOS：在 macOS 上安装 Xcode、命令行工具和 CocoaPods，详见 [macOS 工具链说明](../desktop/macos-toolchain.md)。
- 构建 Windows：在 Windows 上准备 Flutter 桌面工具链和 Visual Studio 的“使用 C++ 的桌面开发”工作负载。

以下命令均从仓库的 `mobile/` 目录执行：

```sh
flutter doctor
flutter pub get
```

## Android

连接已授权 USB 调试的设备后运行：

```sh
flutter run
```

构建 arm64 APK，设置自己服务的 HTTPS 地址：

```sh
flutter build apk --release --target-platform android-arm64   --dart-define=ORIALIS_SERVER_URL=https://orialis.example.com
```

输出为 `build/app/outputs/flutter-apk/app-release.apk`。版本号取自 pubspec；也可在构建时用 `--build-name` 与 `--build-number` 指定。已安装用户的后续更新需要更高的 versionCode 和相同签名。

当前仓库的 release 构建仍沿用 debug signingConfig，见 [Android 构建配置](android/app/build.gradle.kts)。自行正式分发前应配置并保管自己的签名密钥；不同签名的同包名 APK 无法覆盖安装已有版本，换签名前需规划数据迁移。

现成安装包可以在 **我的 → 服务器** 修改地址，不必仅为更换服务器而重新构建。配置跨设备 AI 聊天时，还需匹配客户端的设备 ID，见 [Hermes 接入步骤](../docs/deployment.md#可选接入-hermes-助手)。

## macOS

开发运行：

```sh
flutter run -d macos -t lib/main_desktop.dart
```

构建桌面应用：

```sh
flutter build macos --release --target lib/main_desktop.dart   --dart-define=ORIALIS_SERVER_URL=https://orialis.example.com
```

应用位于 `build/macos/Build/Products/Release/`。对外分发还需完成自己的签名与公证；构建成功不等同于已生成可公开分发的签名安装包。相关包装工具见 [本地桌面发布说明](../desktop/local-release.md)。

## Windows

在已配置 Flutter 的 Windows PowerShell 中运行：

```powershell
flutter run -d windows -t lib/main_desktop.dart
flutter build windows --release --target lib/main_desktop.dart --dart-define=ORIALIS_SERVER_URL=https://orialis.example.com
```

x64 构建的完整输出目录位于 `build/windows/x64/runner/Release/`。分发时保留同目录 DLL 和 data 资源，不要只复制 exe。当前 GitHub 1.3.0 Release 仅提供 Android arm64 APK，桌面端需自行构建和验证。

## 检查

```sh
flutter analyze --no-fatal-infos
flutter test
```

本地数据库的生成代码已提交到仓库。需要修改数据模型时，按 [移动端架构](../docs/mobile-architecture.md) 的开发流程更新并检查生成结果。

## 可选功能

手机端“我的 → 手环连接”提供连接状态与消息诊断。Android 已接入 Xiaomi Wear SDK；真实节点授权与手机／手环互联需按设备验收，见 [Wear README](lib/features/wear/README.md)。

News Android 使用独立入口和构建流程，见 [News 应用说明](NEWS_APP.md)。
