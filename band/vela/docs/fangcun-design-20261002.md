# 方寸参考的 Orialis 手环 UI

Source: user / 2026-10-02 UI reference instruction; read-only `fangcun/apps/fangcun_band/src/pages/{index,menu,tasks,detail,settings}/*.ux`; TASK-023 / COORD-019. Role: orialis-band-coder, owns `band/**`.

## 明确的布局与 token

- 336 × 480 真 Vela：页面与内容宽 100%，左右 16px；禁止将参考固定 300px 宽照搬。子节点不压缩，正文从 scroll 自然增长。
- 纯黑 `#000000`；首页卡 `#191d22`、20px 圆角、16px 内边距、12px 卡间距；菜单与设置 `#1b1f24`、18px 圆角、82–84px 高、10px 间距。
- 44px 圆 glyph：白色 CSS 线图标；菜单蓝 `#265d9f`、青 `#146769`、石板 `#58657b`；首页蓝 `#1f65b8`、青 `#126b72`、橙 `#a86527`。
- 使用系统中文字体。品牌与页标题 27px 粗体；主要文案 22–24px；备注与来源 16–18px。任务行 `#252525` 轻分隔、状态细条，数量为真实列表长度的圆 badge。
- 左对齐内容。48–56px 顶栏、至少 44px 返回触摸区。首页是品牌/短来源 → 主要任务卡 → 手机确认目标与三个独立连接状态 → 功能菜单入口；诊断长文移至设置。

```text
Orialis           empty
[蓝 glyph 当前任务    ›]
[任务标题 / 状态 / 备注]
[青 glyph 执行目标     ›]
[目标名]
[手机 未知 | Orialis 未知 | 目标 未知]
[功能菜单             ›]
```

菜单四条：任务、指令、设备、设置。任务与指令轻列表，详情在本页展开；设备明确手机确认目标和本地预览；设置提供真实本地紧凑/演示开关，禁用震动/通知，缓存清除与 W0 诊断。

## 对照与实施约束

该用户已锁定方寸黑底圆图标与紧凑卡片语言，因此采用该语言，不回退旧 `#161C27` 大文本卡。仅借鉴无冲突视觉结构，未复制方寸脚本、静态时钟或真实完成动作。source badge 始终标记 empty/mock/stale/live；完整 provenance 在页脚与设置。默认 empty，演示需显式开启。

导航使用现有共享 page helper 与 replace，逻辑返回上一层，避免路由堆叠保留多个页实例。只处理平台识别的水平 swipe；右滑在详情先关闭详情。最小 180ms 进入动画，无 haptics、无远程 dispatch。应用单例 store/transport、账号撤销清理及 operationsEnabled=false 保留。

## 验收范围

本次交付源码、当前已有检查和工具链 build；最终 17 项通过（并发既有工作追加 3 项，本 UI worker 未新增测试文件）。root 在 AIoT IDE 复核真实 Vela 页面、滚动与手势；此文不宣称本轮 GUI、腕上 SDK、APK/RPK 签名匹配或真机互联通过。
