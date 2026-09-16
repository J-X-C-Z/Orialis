# Orialis Agent Server 接入清单

这份清单用于把当前 Orialis Server 与 Hermes 插件接到真实服务器。它不包含
任何密钥，也不要求修改 Hermes Core。

## 服务器侧

1. 将 `oris-server` 二进制、`deploy/oris.service` 和
   `deploy/oris.env.example` 部署到服务器 `/opt/oris`，并创建服务用户可读的
   `/etc/oris.env`。
2. 在 `/etc/oris.env` 设置生产值：

   ```env
   ORIS_ENV=production
   ORIS_HOST=127.0.0.1
   ORIS_PORT=18443
   ORIS_DATABASE_URL=sqlite:///var/lib/oris/oris.db?mode=rwc
   ORIS_AGENT_DEVICE_TOKEN=<随机生成的共享设备令牌>
   ```

   令牌只保存在服务器环境文件和 Hermes 的安全配置中，不提交 Git，也不写入日志。
3. 安装 `deploy/nginx/orialis.jxcz.top.conf.example`，确认
   `/api/v1/agent/ws` location 保留 `Upgrade`、`Connection` 和长连接超时设置。
4. 先执行 `nginx -t`，再重载 Nginx；随后重启 `oris.service`。
5. 验证：

   ```text
   GET https://orialis.jxcz.top/api/v1/health
   WebSocket wss://orialis.jxcz.top/api/v1/agent/ws
   ```

## Hermes 侧

配置同一个令牌，但不要复制到仓库文件：

```env
ORIALIS_SERVER_URL=wss://orialis.jxcz.top/api/v1/agent/ws
ORIALIS_DEVICE_ID=<这台设备的稳定 ID>
ORIALIS_DEVICE_TOKEN=<与服务器相同的令牌>
```

设备 ID 每台机器必须不同。插件会在断线后自动重连，并在恢复后继续使用原有
conversation 映射。

## 验收与回滚

先运行 `scripts/agent_gateway_smoke.py` 验证 `message.send → message.ack →
message.reply → message.ack`。若失败，先查看 `journalctl -u oris.service` 和
Nginx error log，不要删除 SQLite 数据库或重建数据卷。

回滚只替换 `/opt/oris/bin/oris-server` 为上一个已验证二进制，然后重启服务；
不要回滚或删除 `/var/lib/oris/oris.db`。
