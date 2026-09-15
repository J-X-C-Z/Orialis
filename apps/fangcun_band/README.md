## 快速上手

### 1. 开发

```
npm install
npm run start
```

### 2. 构建

```
npm run build
npm run release
```

### 4. 代码规范化配置
代码规范化可以帮助开发者在git commit前进行代码校验、格式化、commit信息校验

使用前提：必须先关联git

macOS or Linux
```
sh husky.sh
```

windows
```
./husky.sh
```


## 了解更多

你可以通过我们的[官方文档](https://iot.mi.com/vela/quickapp)熟悉和了解快应用。
# Fangcun Band

当前主适配目标：`xiaomiBandpro`（336 × 480，矩形屏幕）。

## 手机同步

手环端使用 Xiaomi Vela `system.interconnect` 接收 Android companion 发送的 `fangcun.link.v1` 快照。小消息直接接收，大消息使用 `chunk` 分片；全部分片收到后写入手环本地文件，并回复 `fangcun.link.ack`。快照加载后首页、任务页和日程页会使用真实数据，未同步时保留演示数据。

手环 manifest package 与 Android applicationId 均为 `app.fangcun`，这样与社区验证的穿戴通信匹配规则一致。安装时需要把生成的 `.rpk` 安装到目标 Vela 手环，并让小米运动健康保持后台运行。

<<<<<<< HEAD
完整的已验证链路、签名要求和排障基线见仓库文档：[手机—手环互联方案](../../docs/PHONE-WRISTBAND-INTERCONNECT-SUMMARY.md)。

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
在 AIoT-IDE 中选择 `vela-watch-4.0` 镜像创建 `xiaomiBandpro` 模拟器，再运行或调试本项目。页面使用 `device-width` 作为设计宽度，三页均按 336 × 480 的单屏信息密度设计。

## 当前页面

- 首页：下一项日程、地点、倒计时和摘要
- 待办：今日任务与完成切换
- 日程：今日四项安排

## 构建

```bash
npm run build
```

构建产物位于 `dist/`。
