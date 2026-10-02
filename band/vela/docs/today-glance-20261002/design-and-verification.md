# 手环查看优先界面 — TASK-035

来源：user / 2026-10-02；本轮用户确认“现在关注、接下来、最近截止、稍后日程”，四象限纵向四项，手环主要查看、不增加新增项目功能。

## 实现

- 今日四张固定内容卡，单列、每卡只显示分类/数量/首条摘要；点入查看分组，再进入详情。接下来与稍后日程去重。
- 左滑菜单按四象限、项目、日历、设置排列；右滑按详情→分类→菜单→今日逐层返回。今日根页右滑交还系统。
- 四象限四个纵向大行，重要/紧急关系明确写出，颜色仅辅助。未分类独立补充入口，保留数据可达性。
- 移除所有业务新建、编辑、完成、删除、排序、撤销入口及页面写入handler；演示也仅用于查看。手机侧业务不变。
- 336设计基准、黑底、高对比度、两侧20px留白；卡片82px，菜单/象限80px，主要正文26–30px，摘要单行截断后点入阅读。
- 点按一次短震（system.vibrator），250ms节流；无接口、抛错、失败时静默降级。设置可以关闭，滚动和快照刷新不触发。
- 前进/返回180ms单次transform+opacity原生关键帧，设置可减少动画；无持续动画、计时器或JS逐帧布局。应用冷启动不播放入场移动。
- 今日分组/任务象限/项目根列表每批10项；响应式视图有界，离页释放订阅；未加入图像或动画依赖。

## 官方依据与本项目选择

- [多屏设计](https://iot.mi.com/vela/quickapp/zh/guide/design/multi-screens.html)：矩形参考336×480，安全区域要求；公开设备表尚未列10 Pro。本轮验证目标为现有OrialisParity模拟器336×480，不宣称官方证实实际10 Pro尺寸。
- [样式布局](https://iot.mi.com/vela/quickapp/zh/guide/framework/style/page-style-and-layout.html)：designWidth与px缩放；本版显式336。
- [文字组件](https://iot.mi.com/vela/quickapp/zh/components/basic/text.html)：lines与ellipsis；文档默认30px，不是最小字号规定。上述行高/边距/字号是项目设计选择。
- [震动](https://iot.mi.com/vela/quickapp/en/features/system/vibrator.html)：声明system.vibrator与vibrate({mode:'short'})；不用仅部分手表支持的start/stop。
- [动画](https://iot.mi.com/vela/quickapp/zh/components/general/animation-style.html)：keyframes显式0%/100%；transform不用于transition。
- [业务性能](https://iot.mi.com/vela/quickapp/zh/guide/best-practice/business.html)、[内存](https://iot.mi.com/vela/quickapp/zh/guide/best-practice/memory.html)：长列表分批、减少节点与动态更新、清理订阅/定时器。
- [验收标准](https://iot.mi.com/vela/quickapp/zh/guide/publish/acceptance-criteria.html)：FMP≤2000ms。构建耗时不是FMP，本轮不以构建通过证明设备性能。

## 验证

28项自动检查通过；包含四卡稳定与日程去重、分页/详情返回、撤销数据清空、只读入口、短震节流与故障降级、减少动画偏好。官方toolkit构建通过。模拟器交互记录与最终包信息见项目 manager/evidence/wear-today-view-20261002/acceptance.json。

真实腕上震感、帧耗时、功耗、FMP以及手机SDK互联仍需要物理设备验证，模拟器无法代替。

横向手势使用官方[通用TouchEvent](https://iot.mi.com/vela/quickapp/zh/components/general/events.html)的冒泡触点补足不冒泡的swipe：锁定方向、44px水平阈值、垂直滚动不导航、移动后抑制误点击。阈值为项目选择。独立复核发现并修正象限筛选计数、导航环路、删除项残留返回链及部分快照提示。

开发期多次热更新后模拟器发生OutOfMemory/黑屏；停止后完整重装重启，已观察首页左滑菜单、菜单右滑首页。持续压力/内存稳定性没有据此宣称通过。模拟器vibrator返回-138，不将界面开关等同于实际震感。当前运行时对部分边框样式和keyframes打印unknown-style警告；页面可渲染，动画连续帧效果仍需实机核对。
