# Android GitHub 软件更新

Orialis Android 的“我的”页面提供手动检查更新。客户端读取 GitHub 最新正式 Release，使用设备当前安装版本比较，并查找命名为 `Orialis-<版本>-arm64.apk` 的安装包。

下载前要求 Release asset 提供 SHA-256 digest，且发布页与 APK 地址都来自 `github.com/J-X-C-Z/Orialis`。下载到应用私有缓存后，核对文件大小和 SHA-256，再通过 Android FileProvider 打开系统安装器。系统按 Android 的未知来源安装权限要求用户确认；应用不会静默安装。Mac、Windows 和 Web 不显示此入口。

本次静态分析通过；正式 arm64 构建与包签名核对记录在 `deliveries/github-update-20261027/REPORT.md`。Android 安装器中的最终确认仍由设备系统完成。
