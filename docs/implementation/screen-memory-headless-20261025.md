# 屏幕记忆：不打开 App 的后台分析

> 1.1.0统一发布状态与使用说明见[版本记录](../releases/1.1.0.md)。下文保留各模块交付时的源码/部署验收边界。

已确认旧流程依赖 MainActivity 中的 MemoryBridge 和 Flutter MemoryCoordinator。保存后若不打开 App、且进程没有活跃 Flutter 界面，旧流程只保存截图，无法立即启动分析。本次新增系统 JobScheduler 任务及 headless Flutter 入口，继续复用现有 MemoryCoordinator、MemoryAnalyzer、AppConfig 安全登录存储和专用记忆 API；不新建聊天或复制登录凭据到原生偏好设置。

统一触发点是 MemoryStore.save：传统截屏、无障碍截屏和分享保存都自动安排同一个系统任务。无需在各捕获 Activity 中增加钩子。新任务桥独立于主 MemoryBridge，不创建或替换其 active 实例；MemoryBridge 的截屏状态和设置入口由截屏模块维护。任务不会创建 MainActivity，完成后仅向现有活跃桥通知记录更新。

后台桥绑定任务启动时的账号范围，setScope 只校验一致性，不修改当前账号。每次远程操作前还通过原生 isCurrent 确认账号未切换，并刷新跨 Flutter 引擎的偏好缓存；记录读写均继续在 MemoryStore 的同步范围内核验。沿用稳定 memory-v2 任务 ID，前台与后台同时恢复时由服务端复用同一任务。Dart 执行预算330秒、原生兜底350秒，任务完成、系统停止或超时后销毁引擎；被中断的 analyzing 任务可在下次调度复用已有 ID 恢复。

前台重试和后台恢复可并行执行：MemoryAnalyzer持有任务ID后，每次检查同时核对记录的analysisRequestId，不同ID视为取消。最终成功或失败提交还携带expectedAnalysisRequestId，主桥和后台桥都在MemoryStore同步锁内比较并写入，避免Dart检查之后才发生的重试被旧结果覆盖。这只是本机存储调用参数，没有改变服务器API、协议或数据库。引擎临时启动失败不再把任务当作完成，而是在onStartJob返回后调用jobFinished，按既有30秒指数退避规则重试仍待处理的记录。

验证：新增5项后台入口测试覆盖冷入口分析、不触发界面或捕获、账号撤销、迟到结果及预算中断；新增3项并发回归覆盖双实例旧成功/失败迟到及最终原生提交前的竞态。连同记忆分析/API/记录/页面测试共48项通过。目标Dart文件 analyze无问题；Android compileDebugKotlin通过（Android Studio内置JBR，日志 /tmp/orialis-memory-background-kotlin.log）。没有安装手机包或做实体手机冷进程验收。JobScheduler 的实际启动时机仍受系统联网条件、任务额度及省电策略影响。

实现文件：MemoryAnalysisJobService.kt、memory_background.dart、main.dart、MemoryStore.kt；主Manifest注册带 BIND_JOB_SERVICE 保护的服务，资讯独立包移除此服务。

依据：[Android JobService](https://developer.android.com/reference/android/app/job/JobService)、[FlutterEngine后台执行](https://api.flutter.dev/javadoc/io/flutter/embedding/engine/FlutterEngine.html)、[DartEntrypoint](https://api.flutter.dev/javadoc/io/flutter/embedding/engine/dart/DartExecutor.DartEntrypoint.html)。
