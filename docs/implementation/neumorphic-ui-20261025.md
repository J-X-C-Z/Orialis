# Android 轻拟态测试 UI

用户要求独立分支试验轻拟态 UI，并明确选择 Flutter Android。

分支：`codex/neumorphic-ui-test`；基线：`817cc3c19c80ec66d850cd4734d44aad8f8ca1f2`（1.1.0）。独立工作区 `projects/orialis/ui-neumorphic` 与既有 `repo`、`repo-latest` 属于同一 Git 仓库。旧工作区的未提交改动未带入或修改。源码未提交、推送或发布。

## 视觉与实现

参考用户提供的 [Neumorphism.io](https://neumorphism.io/#e0e0e0)、[Neumorphism UI](https://neumorphism-ui.andongmin.com/en) 和 [Dribbble](https://dribbble.com/search/Neumorphism-UI)。在浏览器查看了前两个网站实际材质与组件，第三个页面读取了设计参考列表。

浅灰 `#E0E0E0` 作为页面和组件共同材质，主字色 `#303947`、辅助字色 `#58616F`、蓝色强调 `#385DAD`，左上光 `#FAFAFA`、右下阴影 `#B7B7B7`。保留系统字体与原有文字尺度，以内容左对齐和现有五页结构为基础。凸起卡片、凹陷输入框及选中项、按下变凹构成主要层次；取消本模式的玻璃模糊、放大透镜、颗粒纹理和文字浮雕。保留深色模式、焦点轮廓、高对比度边界、减少动态效果设置。

通过 `LuminaThemeData.neumorphic` 选择材质，默认 false；仅此分支的手机主应用打开，桌面仍使用原主题。共享画笔负责普通卡片、惰性列表整卡、按钮、输入框、分段控件和弹窗材质，保留原业务和五页路由。底部导航用凸起底座与凹陷选中项，保留长按拖动切换、键盘避让和聊天会话隐藏策略。

## Android 测试包

设置 `ORG_GRADLE_PROJECT_neumorphicApp=true` 构建，应用 ID 为 `top.jxcz.orialis.neumorphic`，名称“Orialis 轻拟态”，独立存储，可与正式版并存。小米注册配置不带入此独立包。没有自动安装、覆盖正式版或更改服务器。

```sh
cd mobile
ORG_GRADLE_PROJECT_neumorphicApp=true flutter build apk --debug --target-platform android-arm64
```

这是界面与应用功能试验包；联网登录仍使用用户自行选择的账号与服务器，登录后的同步和写入沿用现有业务。

## 验证

- 组件测试 42 项通过：新增轻拟态明/暗输入、分段选择、按压交互检查，既有液态玻璃、基础组件、日期选择无障碍和主题过渡回归通过。
- 既有手机五页流程测试通过：新建任务持久化、日历日/周/月切换、聊天和个人页离线操作均成功。
- 独立预览流程通过（1 项）：内存数据库合成数据，切换明/暗、创建任务、五页导航和 360px 窄屏，生成七张实际 Flutter 渲染截图。预览使用本机 Arial Unicode 字体，真机仍使用系统字体。
- 新增底部导航测试通过（1 项）：360px、两倍字号，长按拖动在松手时提交，键盘出现时底栏不响应点击，收起键盘后可点击切页。
- 共享组件源码与新增组件测试 `dart analyze`：No issues found。
- 手机改动文件静态检查首次只发现测试的一处 const 提示，已修正；最终针对改动文件的 dart analyze 为 No issues found。
- Android debug arm64 APK 构建成功（894.5 秒），aapt 回读独立包 ID、版本 1.1.0+11、名称正确。
- 当前 USB 小米 2210132C（本轮发现序列 83626d06）`install -r` 返回 Success，冷启动 Status ok，进入实际应用界面；启动日志未发现 FATAL EXCEPTION。
- 正式版仍同时安装，版本与 firstInstallTime/lastUpdateTime 在安装前后相同。未卸载、清数据或替换正式包。
- 初始轻拟态 APK、SHA256、源码 patch、七张软件预览和真机截图保存在交付目录。此快照为后续玻璃融合工作前的已安装基线。

截图与命令日志保存在 `deliveries/neumorphic-ui-20261025/`。这些是 Widget 和软件渲染验收，不是真机启动、系统键盘或完整在线服务验收。

项目外层历史 `project.yaml`、`state.md`、`roadmap.md`、`memory/summary.md` 和 `memory.db` 当前不存在；只读参考外层 Git 历史元数据，不恢复旧管理文件。本记录与 TASK-024、COORD-020 保存当前状态，长期已确认结论同步共享库 `aw-orialis`。
