# Orialis Agent Server 接入清单

这份清单用于把当前 Orialis Server 与 Hermes 插件接到真实服务器。它不包含
任何密钥，也不要求修改 Hermes Core。

## 服务器侧

1. 将 `orialis-server` 二进制安装到 `/opt/orialis/bin/orialis-server`，将
   `deploy/orialis.service` 安装为 `/etc/systemd/system/orialis.service`，并依据
   `deploy/orialis.env.example` 创建服务用户可读的 `/etc/orialis.env`。不要把
   systemd unit 或生产环境文件放进 `/opt/orialis`；该目录只用于应用文件。
2. 在 `/etc/orialis.env` 设置生产值：

   ```env
   ORIALIS_ENV=production
   ORIALIS_HOST=127.0.0.1
   ORIALIS_PORT=18443
   ORIALIS_DATABASE_URL=sqlite:///var/lib/orialis/orialis.db?mode=rwc
   ORIALIS_AGENT_DEVICE_TOKEN=<随机生成的共享设备令牌>
   ```

   令牌只保存在服务器环境文件和 Hermes 的安全配置中，不提交 Git，也不写入日志。
3. 安装 `deploy/nginx/orialis.jxcz.top.conf.example`，确认
   `/api/v1/agent/ws` location 保留 `Upgrade`、`Connection` 和长连接超时设置。
4. 先执行 `nginx -t`，再重载 Nginx；随后重启 `orialis.service`。
5. 验证：

   ```text
   GET https://orialis.jxcz.top/api/v1/health
   WebSocket wss://orialis.jxcz.top/api/v1/agent/ws
   ```

部署前必须用目标数据库做一次 SQLx migration checksum 预检。旧生产环境可能
使用 `/opt/oris`、`oris.service` 和 `/var/lib/oris`（而不是本仓库示例中的
`orialis` 路径）；应以 `systemctl cat oris.service` 和 `/etc/oris.env` 为准。
可把目标环境的 migrations 目录只读复制到临时目录后运行：

```sh
python scripts/check-migration-checksums.py --reference-dir /path/to/reference/migrations
```

若旧 migration 的字节内容与当前工作树不同，即使只是注释，也会触发
`VersionMismatch`。此时停止发布、保留旧二进制并回滚，禁止直接修改
`_sqlx_migrations` 表；应在隔离构建副本中复现并制定兼容升级方案。

## Hermes 侧

配置同一个令牌，但不要复制到仓库文件：

```env
ORIALIS_SERVER_URL=wss://orialis.jxcz.top/api/v1/agent/ws
ORIALIS_DEVICE_ID=JXCZ_MBA_Hermes
ORIALIS_DEVICE_TOKEN=<与服务器相同的令牌>
```

设备 ID 每台机器必须不同。插件会在断线后自动重连，并在恢复后继续使用原有
conversation 映射。

## 验收与回滚

先运行 `scripts/agent_gateway_smoke.py` 验证 `message.send → message.ack →
message.reply → message.ack`。若失败，先查看 `journalctl -u orialis.service` 和
Nginx error log，不要删除 SQLite 数据库或重建数据卷。

回滚只替换 `/opt/orialis/bin/orialis-server` 为上一个已验证二进制，然后重启服务；
不要回滚或删除 `/var/lib/orialis/orialis.db`。
