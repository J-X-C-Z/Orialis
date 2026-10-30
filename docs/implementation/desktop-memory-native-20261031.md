# macOS 记忆捕获桥

原生实现：`mobile/macos/Runner/MainFlutterWindow.swift`，共用 `top.jxcz.orialis/memory`。

应用启动即注册全局快捷键：⌥⌘M 记录主屏幕静态截图，⌥⌘N 记录前台应用选中文字。未登录时快捷键显示原生登录提示且不保存；关闭主窗口后继续运行，点击 Dock 图标恢复窗口。需要 Orialis 保持运行，退出应用才注销快捷键。成功捕获不激活 Orialis、不发送复制按键、不读写剪贴板；失败会激活原生提示框，避免后台 Flutter 提示不可见。用户触发截图时请求屏幕录制权限；选中文字通过 Accessibility 只读访问，缺权限请求辅助功能授权。当前应用不提供选区时明确失败，不用剪贴板猜测。

支持 `status/setScope/list/read/update/delete/prepareUpload/capture/captureSelection/openCaptureSettings/takePendingRoute/requestAddTile`。`capture` 为截图，`captureSelection` 为选中文字，`takePendingRoute` 为 null，`requestAddTile` 为 false。成功通过 `memoryChanged {id}` 通知现有 Dart 分析协调器；快捷键失败通过 `captureError {code,message}` 通知界面；方法调用失败返回 FlutterError。

记录位于 Application Support/Orialis/Memory/<scope SHA256>，目录权限0700、记录/截图0600，JSON原子写入。更新分析字段支持expectedAnalysisRequestId条件保护，截图异步完成后再次核对scope。prepareUpload保留原始PNG，生成小于900KiB的临时JPEG副本；先按最大边1600和质量0.75编码，必要时降低尺寸和质量。删除仅处理指定UUID记录及同名截图。

验证：原文件 swiftc -parse 通过；用真实 FlutterMacOS framework 对同源（仅剔除生成插件注册函数调用）swiftc -typecheck 通过。系统授权、真实跨应用选区与全局快捷键需最终应用运行验收。本轮未修改Windows原生宿主。

自定义快捷键：getShortcuts 与 setShortcuts 共用 `{screen:{key,command,option,shift,control},selection:{...}}` 完整字典。键限A–Z/0–9，至少Command/Option/Control之一，两项不能重复。设置先尝试Carbon注册，失败回滚原注册及配置，成功后才写入UserDefaults。启动读取持久配置，格式异常回默认。录入界面通过suspendShortcuts暂停注册，关闭时finally调用resumeShortcuts；暂停期间set仍验证冲突。原生回归自检覆盖36键、默认往返、重复及非法组合拒绝，Swift类型检查通过。
