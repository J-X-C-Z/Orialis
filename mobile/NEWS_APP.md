# Orialis 资讯

电脑端的 AI Hot、GitHub 和 Project 是 Orialis 桌面主应用的三个一级导航入口，与“今日”“任务”“项目”“日历”平级；共用主应用账号、服务地址和外观设置。不要构建或发布独立 macOS 资讯应用，也不要增加“资讯”总入口。

Android 可继续使用独立 Dart 入口 `lib/main_news.dart`，不启动主产品的同步协调器。资讯包通过 `./mobile/build_news_android.sh` 单独构建，包 ID 为 `top.jxcz.orialis.news`，应用名为“Orialis 资讯”。

桌面新闻仓库使用主应用提供的 `appConfigProvider`，按服务地址、Session token 的 SHA-256 摘要和请求路径隔离缓存。新闻 API 需要 Session；缺少或失效会话时显示对应登录状态，401/403 会清除此会话范围缓存并要求重新登录。Project 导航展示项目秘书报告，不替换已有“项目”管理页。
