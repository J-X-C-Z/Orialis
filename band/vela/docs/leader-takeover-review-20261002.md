# 手环组长接管复核 — 2026-10-02 22:05 +08:00

范围：ORI-72 / TASK-023，唯一权威 band/**。已读项目 AGENTS、project.yaml、state/roadmap、TASK-023/COORD-019、ORI-68路线图与ORI-69源码、手机Wear README。未修改 mobile 或其他组源码，未改迁移记录/源文件。

## 本轮实际修复

启动 storage.get(cache.guard) 尚未返回时，transport.receive(snapshot.part) 原来可排队写入并在回读后ACK，即使磁盘guard实际已撤销。读取失败也没有阻止后续快照。本轮通过延迟guard回调及失败回调注入重现：两项新回归原版均失败（写队列长度1，预期0）。

transport.cacheReady现在仅在有效guard（含兼容W0的空guard）恢复后，或当前generation的guard写入及旧缓存删除成功后开启。恢复/清理中、损坏/读取失败、删除失败或销毁时不接收快照，不持久化/ACK。Ping/Pong不受快照门槛影响。未添加可信会话RPC；scope仍只能由未来经过验证的companion adapter提供。撤销guard会继续由store拒绝输入。发送方收到拒收应在恢复完成后显式重试只读快照，禁止敏感操作重放。

## 本轮验证

- node --test test/*.test.js：19通过/0失败；新增2项先失败后通过，涵盖延迟撤销guard、读取失败、空guard兼容W0。
- node --check src/services/transport.js：通过。
- npm run build：toolkit2.0.5 / Node26.8.1，官方编译成功；本次日志profile development、enableJsc=false、watch=false。
- 当前manifest：top.jxcz.orialis / 0.2.1-ui / versionCode3；冻结包 ../artifacts/leader-review-20261002-2205.rpk，143036 bytes，SHA256 9cf7bdccd399d521d2f0e0f2c40e7979d94e981188c81176b946e7c1a3000856。
- 证据日志：leader-review-tests-20261002.txt、leader-review-build-20261002.txt。

本次包仍toolkit开发签名，不能当匹配手机的实机包。早先64,786字节JSC包和142,639字节IDE watch包均为不同profile/旧源码证据，不能用于本次修复包哈希。

## 有效后续路径

- ORI-74（组员2beea5f3）：当前版真实模拟器Commands/确认说明/等待/失败、五页/水平返回截图与日志。不得引用旧0.2.0图作为当前验收。
- ORI-75（组员c3554cb4）：独立协议/缓存复核，含本次修复、guard错误/撤销与计时器；与ORI-73手机组长落实可信会话通知来源、只读投影和联调矩阵。
- 已在ORI-73线程写入交接（comment 6f06c2c4-ee35-4952-9a83-529a0a33f48b）。本组长收到两项成果后独立复核，再判定UI阶段交付；本轮不宣称成员已运行或成果已验收。

## 未通过

本轮只检查源码/本地harness/构建，未进行模拟器视觉操作。旧UI真实模拟器证据见fangcun-handoff与外层acceptance.json；最终Commands和水平手势仍待独立复核。真实SDK/AAR、账号/companion会话通知源、业务只读API投影、APK/RPK匹配签名、腕上安装/发现/Ping/Pong/重启缓存/后台恢复未通过。任务停止、执行、Agent控制和审批保持禁用。本轮未重新检查ADB，不沿用历史状态作当前结论。

构建输出dist被运行中的IDE构建更新/清理，首次冻结副本未保留下来；已将最终交接副本移到 band/artifacts/，避免IDE清理。该包采用当前源码开发profile，最终大小与哈希以本报告及上传副本为准。
