# 屏幕记忆服务端部署（2026-10-25）

状态：API和Azure Hermes插件已上线；公网AI分类、图片理解、认证和重复提交验收通过。B站412随后通过用户专门扫码授权及单文件修复解决，公网视频理解与AI分类验收通过，详见[bilibili-412-diagnosis-20261025.md](bilibili-412-diagnosis-20261025.md)。下文保留首轮发布时的历史快照。手机端由用户指定的其他会话统一发布，本次未构建或安装手机包。

## 目标与构建

1. 目标为 `aozora-my`：Ubuntu24.04.4 LTS、Linux x86_64、glibc2.39；API服务 `oris.service`，程序 `/opt/oris/bin/oris-server`，数据库 `/var/lib/oris/oris.db`。插件由同机 `hermes-gateway.service` 运行。
2. 本地和目标机均确认候选/回滚文件为Linux x86_64 ELF，`ldd`通过，最高需要glibc2.34。版本通过隔离启动后的健康接口核对为1.0.0。没有使用macOS Mach-O程序。
3. 生产机只有842MB内存，独立Linux构建主机暂不可达，因此使用已有固定工具链：Rust/Cargo1.98.1、cargo-zigbuild0.23.4、Zig0.17.0，执行 `cargo zigbuild --target x86_64-unknown-linux-gnu.2.34 --release --locked -p orialis-server`，在目标机做最终验证。精确发布源码执行 `cargo test --workspace --release --locked`：核心10项、服务端147项全部通过；Linux记忆专项9项通过。Linux全量负载测试曾达到专用测试进程的256MB内存+256MB swap限额，未调高生产机限额；只终止测试进程，线上API保持正常，对应完整负载测试已在本地精确源码release测试中通过。
4. 生产数据库已应用的0..18共19个迁移SHA384全部逐字节匹配；仓库预检脚本通过21个迁移文件，新增0019/0020。切换后确认0..20全部成功且校验一致，未修改历史迁移或迁移记录。

本次从Git基础源码生成隔离发布快照，仅叠加屏幕记忆服务改动及其测试。线上历史Rust源码与基础源码的行为比对一致；未发布其他会话尚未提交的health/UI/聊天变更。Hermes插件以线上实际副本为基础，只叠加记忆处理，保留线上response_ui等内容。

## 发布和回滚

发布ID：`memory-video-20261025-163128`。

- 候选程序：`/opt/oris/releases/memory-video-20261025-163128/oris-server.candidate`，SHA256 `74f6c71f2cf86a2508b6aa07f481c0843e26dac290372a0b3d1ebdf766f507e6`。
- 兼容回滚程序：同目录 `oris-server.rollback`，SHA256 `fbaff0334c3c0e2201a7e8a891d01ed8ba2d49a1472ac6a5e4d1f263173f9f01`。
- 旧程序备份：同目录 `backup/oris-server.previous`，SHA256 `c69c5218aa1a65f610e17764d6b7bc7206b9d50dc28302c7a6fed75372336692`。
- 一致性数据库快照：同目录 `backup/oris.pre-deploy.sqlite`，完整性检查通过，权限600，备份目录700。仅保存在服务器，不复制个人数据库到本机。
- 插件暂存：`/home/hermes/.hermes/releases/orialis-memory-20261025-0035/plugin`；备份：`/home/hermes/.hermes/backups/orialis-memory-20261025-0035/plugin`。

兼容回滚程序保持发布前API行为，同时包含新迁移的嵌入校验信息，已验证能在升级后的同一测试数据库启动并保留记忆数据。实际回滚应切换此兼容程序并重启API；不要用数据库备份覆盖上线后产生的新数据，也不要直接使用不认识新迁移的旧原始程序。

API切换脚本会在启动、健康、迁移或首请求失败时自动切换兼容回滚程序。API本次未触发回滚。

## 线上验收

- API：`active/running`，PID1697308，`NRestarts=0`，公网健康接口200；未触发回滚。启动窗口未发现panic或迁移错误。
- Hermes：`active/running`，PID1700945，`NRestarts=0`；网关状态PID一致，Orialis为connected，API设备列表确认 `JXCZ_AOZORA_Hermes` 在线；未触发回滚。
- 插件当前文件与暂存文件哈希一致；原线上response_ui SHA256保持 `62b29098eccbaad04b43bccb267733e4324164c37f9f039b466e6bcfedcdfc73`，非记忆文件逐字节保留。adapter/protocol保持原CRLF，部署哈希分别为 `a50577ae0a9243fd2c6655b5319cffa019b0439f8bb8ec4485d625a875c87d09`、`f3bbc054db8ab3074d9e86afed7b20fbaf83cad9b8bb4e0737d5fc5c9854317b`。
- 真实链路：Mac通过公网API，以短期专用测试Session提交，经线上API转交Azure Hermes，结果写入专用记忆表。AI文本返回 `completed/category=ai`；512px受控图实际识别红底及ZX7，图片理解通过。
- 三个任务分别重复POST，仍只产生三个记忆任务。无认证访问返回401，Azure目标设备在线；测试ID未产生对应聊天/消息记录。临时Session及三个测试任务均已按精确ID清理。
- B站公开测试保留原始URL并返回 `completed/videoStatus=unavailable` 和明确原因，没有伪造videoSummary。**该服务器上的B站内容读取尚未成功，不把异常处理通过写成视频识别验收通过。**
- Azure本机访问自身公网API收到403，因此没有把该请求当作后台故障或放开安全配置；公网验收改由Mac发起。Mac公网访问及服务器本地18443健康/认证均正常。
- 发布前后账号数量保持10，原有项目/任务/聊天数据保留；期间正常新增任务和聊天持续存在。最终只读核对为任务73、项目5、会话47、消息405、附件25、现有Session20；这些是验收时快照，不是未来不变的数值。

生产环境预检确认Python3.14.7、Pillow12.3.0及原有辅助模型配置可用，暂存插件在生产解释器中26项测试通过。512px红底、黑X、白色ZX7合成图识别正确，无需调整模型配置。

B站官方公开视频API在该Azure出口返回HTTP412；普通UA和完整浏览器UA均相同。模型识图与B站内容获取分别记录，不把平台风控时的截图/标题摘要当作完整视频理解。遇到该情况保留原链接并返回 `videoStatus=unavailable` 和可重试原因。

## 手机会话交接

交接文件：`/Users/jxcz/Agent Workspace/projects/orialis/deliveries/memory-video-20261025-163128/mobile-handoff.md`。手机端仍应沿用现有Session认证和用户账号，更新后使用新的记忆界面、稳定v2任务ID、分类与视频结果字段。旧手机包继续兼容既有API，新的后台提交流程在手机统一升级后启用。

精确构建和预检证据：发布目录的 `linux-artifacts/build-manifest.json`、`migration-preflight.json`、`manifest.json`；服务器端保存 `server-promotion.json`、最终 `acceptance.json` 和 `postflight.json`；本机同一发布目录保存 `acceptance-public.json`、`hermes-promotion.json`。所有证据不包含会话令牌或服务密钥。
