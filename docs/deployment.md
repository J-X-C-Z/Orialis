# Orialis 自托管部署指南

本文以 Debian / Ubuntu、systemd 和 Nginx 为例，部署自己的 HTTPS 同步服务，并按需接入 Hermes 助手与 Web 客户端。基础任务、项目和日历同步只需要 Orialis 服务端，Hermes 是 AI 聊天的可选组件。

## 1. 部署前准备

准备一台运行 systemd 的 Linux 主机、指向该主机的域名、开放的 80/443 端口，以及 Linux Rust 构建环境。生产 API 绑定回环地址，由 Nginx 提供 HTTPS。Android 可未登录本地使用；注册登录后才同步到自托管服务。

下文需要自行替换的站点值为 `orialis.example.com`（你的域名）和客户端地址 `https://orialis.example.com`。命令生成的 `ORIALIS_AGENT_DEVICE_TOKEN` 是自动生成的秘密，私下保存并原样配置到 Hermes，不能提交到 Git 或写入公开日志。首次注册的用户名和密码由你自行设定。

## 2. 在 Linux 构建服务

下面从一台支持 systemd 的 Debian / Ubuntu Linux 主机开始，直接在目标主机上构建。若使用另一台构建机，应与服务器架构和运行环境匹配；不要把 macOS 构建出的程序复制到 Linux 上运行。

安装系统工具：

```sh
sudo apt update
sudo apt install -y build-essential pkg-config libsqlite3-dev sqlite3 ca-certificates curl git openssl nginx certbot
```

服务端要求 Rust 1.88 或更新版本。尚未安装 Rust 时，按 [rustup 官方安装说明](https://rustup.rs/) 执行并选择默认安装：

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
rustup toolchain install stable
```

获取与当前正式版一致的源码并构建：

```sh
git clone --branch v1.3.0 --depth 1 https://github.com/J-X-C-Z/Orialis.git
cd Orialis
cargo +stable build --locked --release -p orialis-server
```

产物为 `target/release/orialis-server`。后文系统服务命令继续从该仓库根目录执行。选择自己的域名，后续 shell 示例在同一终端复用这个变量；请在这里换成实际域名，换新终端后重新设置：

```sh
orialis_domain=orialis.example.com
```

服务只读取进程环境，不会自动读取仓库 `.env`。本文使用 systemd 模板的 `EnvironmentFile=/etc/orialis.env` 注入配置。

## 3. 建立账户与目录

以下与真实 systemd 模板一致：账户和组均为 `orialis`，工作目录 `/opt/orialis`，环境文件 `/etc/orialis.env`，数据目录 `/var/lib/orialis`。

```sh
sudo useradd --system --user-group --home-dir /var/lib/orialis --shell /usr/sbin/nologin orialis
sudo install -d -o root -g root -m 0755 /opt/orialis /opt/orialis/bin
sudo install -d -o orialis -g orialis -m 0750 /var/lib/orialis /var/lib/orialis/uploads
sudo install -o root -g root -m 0755 ./target/release/orialis-server /opt/orialis/bin/orialis-server
```

`/opt/orialis` 由 root 管理，服务不能改写程序；只有 `/var/lib/orialis` 与上传目录可写。若账户已存在，跳过 `useradd`，并确认其组和目录权限正确。

## 4. 配置环境并启动

复制模板并编辑：

```sh
sudo install -o root -g orialis -m 0640 deploy/orialis.env.example /etc/orialis.env
sudoedit /etc/orialis.env
```

保持模板中的 `ORIALIS_ENV=production`、`ORIALIS_HOST=127.0.0.1`、`ORIALIS_PORT=18443`、SQLite URL、上传路径与 `ORIALIS_DEV_DEVICE_AUTH=false`。将 `ORIALIS_PUBLIC_URL` 改为 `https://orialis.example.com`（替换为你的实际域名）。需要接入 Hermes 时，生成 Agent Gateway token：

```sh
openssl rand -hex 32
```

把生成的值作为 `ORIALIS_AGENT_DEVICE_TOKEN` 加到 `/etc/orialis.env`，后续 Hermes 使用同一值。不接入助手时可暂不设置；任务和日历同步仍可使用。安装并启动服务：

```sh
sudo install -o root -g root -m 0644 deploy/orialis.service /etc/systemd/system/orialis.service
sudo systemctl daemon-reload
sudo systemctl enable --now orialis
sudo systemctl status orialis --no-pager
sudo journalctl -u orialis -n 100 --no-pager
```

启动时服务会自动执行 `orialis-server/migrations/` 内尚未应用的迁移。先检查本机接口：

```sh
curl --fail-with-body -sS http://127.0.0.1:18443/api/v1/health
```

看到 `"ok":true` 后继续配置 HTTPS。如果启动失败，先检查日志和 `orialis` 对 `/var/lib/orialis` 的写权限。

## 5. 配置 HTTPS 反向代理

将域名的 DNS A 记录指向服务器；如配置 AAAA，也应指向能访问这台服务的 IPv6 地址。确保公网能访问该域名的 80/443 端口。

先建立用于签发证书的 HTTP 站点。以下会创建或替换本应用的 `/etc/nginx/sites-available/orialis`，已有部署先备份该文件：

```sh
sudo install -d -m 0755 /var/www/certbot
sudo tee /etc/nginx/sites-available/orialis >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${orialis_domain};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF
sudo ln -sfn /etc/nginx/sites-available/orialis /etc/nginx/sites-enabled/orialis
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/certbot -d "$orialis_domain"
```

根据 Certbot 提示填写联系邮箱并完成签发，然后安装仓库中的完整 HTTPS 模板：

```sh
sed "s/orialis\.jxcz\.top/${orialis_domain}/g" deploy/nginx/orialis.jxcz.top.conf.example \
  | sudo tee /etc/nginx/sites-available/orialis >/dev/null
sudo nginx -t
sudo systemctl reload nginx
sudo certbot renew --dry-run
```

该模板包含普通 API、Agent WebSocket、手机客户端 WebSocket 和 SSE 的代理规则，以及附件上传大小设置。保持服务端监听 `127.0.0.1:18443`，由 Nginx 对外提供 HTTPS。

## 6. 检查服务并注册账户

先检查自己的 HTTPS 地址：

```sh
curl --fail-with-body -sS "https://${orialis_domain}/api/v1/health"
curl --fail-with-body -sS "https://${orialis_domain}/api/v1/capabilities"
```

健康接口应返回 `"ok":true`，能力接口显示该服务器实际支持的功能。`health.version` 是服务端自身版本字段，不必与 Android 版本号相同。

接下来安装客户端，在 **我的 → 服务器** 填入 `https://你的实际域名`，再点击顶部的 **未登录** 注册首个账户。用户名长度为 3–32，密码长度为 8–128；已有账户则直接登录。也可通过 [认证 API](api-v1.md) 注册，返回的 `accessToken` 是会话凭据。

接入助手时，数据库只有一个账户可自动绑定该账户；多账户需设置 `ORIALIS_AGENT_USER_ID`。具体配置见 [Hermes 接入](#可选接入-hermes-助手)。

## 7. Android 客户端

正式 Android 发布为 **1.3.0 arm64**（Android 7.0 及以上）。从 [GitHub Release](https://github.com/J-X-C-Z/Orialis/releases/tag/v1.3.0) 下载 `Orialis-1.3.0-arm64.apk`；校验和见 Release 附件 `SHA256SUMS`。当前 release 沿用 debug 签名。其他平台的实际构建入口、前置条件和发布附件见 [`mobile/README.md`](../mobile/README.md)。

安装后打开“我的 → 服务器”，将地址改为 `https://你的域名`，然后注册或登录。未登录仍可本地使用；登录后才同步到该服务。首次连接要求有效 HTTPS 证书。地址保存在客户端本地。认证接口说明见 [`api-v1.md` 注册与登录](api-v1.md#3-认证接口)。

现成 APK 的聊天路由只显示以下四个固定槽位。它们是公开路由键，不是账户名或秘密；Hermes 的 `ORIALIS_DEVICE_ID` 必须与目标槽位完全一致。

| 客户端槽位 | 默认设备 ID |
| --- | --- |
| Mac 电脑 | `JXCZ_MBA_Hermes` |
| Windows 电脑 | `JXCZ_PC_Hermes` |
| Hakari 服务器 | `JXCZ_HAKARI_Hermes` |
| Azure 服务器 | `JXCZ_AOZORA_Hermes` |

任意自定义 ID 即使在线，也不会显示在现成 APK 聊天列表。使用自定义值需构建时设置对应 dart-define：`ORIALIS_MAC_CHAT_DEVICE_ID`、`ORIALIS_WINDOWS_CHAT_DEVICE_ID`、`ORIALIS_HAKARI_CHAT_DEVICE_ID` 或 `ORIALIS_AZURE_CHAT_DEVICE_ID`。设备 ID 仍须符合 `<USER>_<DEVICE>_<Agent>` 格式。示例：

```sh
cd mobile
flutter build apk --release --target-platform android-arm64 \
  --dart-define=ORIALIS_SERVER_URL=https://orialis.example.com \
  --dart-define=ORIALIS_AZURE_CHAT_DEVICE_ID=MYPC_HOME_Hermes
cd ..
```

随后让对应 Hermes 使用 `ORIALIS_DEVICE_ID=MYPC_HOME_Hermes`；其他槽位同理。上表的显示名称可以在应用中重命名，路由 ID 仍需对应。

## 可选：接入 Hermes 助手

### 安装 Hermes 并准备模型

Hermes 可以运行在同一台服务器，也可以运行在你的电脑或另一台 Linux 主机。先按 [Hermes 官方安装指南](https://github.com/NousResearch/hermes-agent#quick-install) 安装，运行其配置向导设置可用模型和供应商凭据，确认 Hermes 本身能够正常回复。Orialis 不代替模型服务，也不要求使用特定供应商。

以下是 Linux / macOS 示例，从 **Hermes 所在主机上的 Orialis 仓库根目录**执行。`orialis_hermes_home` 应指向你要接入的实际 profile；默认值适用于默认 profile，已有命名 profile 请改为其实际路径。

```sh
orialis_hermes_home="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "$orialis_hermes_home/plugins/platforms/orialis"
cp -a integrations/hermes/orialis/. "$orialis_hermes_home/plugins/platforms/orialis/"
```

这是目录插件，需整体保留 `plugin.yaml`、`__init__.py` 和同目录模块。已有插件升级前先保留旧目录副本。

### 配置 token 与账号归属

在服务端 `/etc/orialis.env` 设置随机的 `ORIALIS_AGENT_DEVICE_TOKEN`，在目标 Hermes profile 的 `.env` 中设置：

```dotenv
ORIALIS_SERVER_URL=wss://orialis.example.com/api/v1/agent/ws
ORIALIS_DEVICE_ID=JXCZ_AOZORA_Hermes
ORIALIS_ALLOWED_USERS=JXCZ_AOZORA_Hermes
ORIALIS_DEVICE_TOKEN=替换为服务端的同一个Agent-token
```

替换域名与 token；如果选择了别的槽位，两个设备 ID 值一起替换。`ORIALIS_ALLOWED_USERS` 应精确等于该设备 ID。服务端与插件的变量名不同，但 token 的值必须相同。

数据库只有一个用户时，服务端会自动确定助手的账号归属。多用户时，在服务端查询要绑定的账号标识：

```sh
sudo -u orialis sqlite3 /var/lib/orialis/orialis.db 'SELECT id,username FROM users;'
sudoedit /etc/orialis.env
```

设置 `ORIALIS_AGENT_USER_ID=目标账户的id`。它是账号 ID，不是用户名，也不是 Session token；同一服务端 Agent token 对应这个账户。修改服务端环境文件后：

```sh
sudo systemctl restart orialis
```

在 Hermes profile 的现有 `config.yaml` 中**合并**以下工具集配置，保留其他模型、平台和工具设置：

```yaml
platform_toolsets:
  orialis:
    - hermes-cli
    - orialis
```

### 启用并检查连接

```sh
HERMES_HOME="$orialis_hermes_home" hermes plugins enable platforms/orialis
HERMES_HOME="$orialis_hermes_home" hermes plugins list --enabled
HERMES_HOME="$orialis_hermes_home" hermes gateway run
```

根据 Hermes 提示确认加载插件。插件启用后，配置中的连接变量用于启动 Orialis 平台；只复制文件不会自动启用插件。`gateway run` 在前台运行，保持进程在线才能使用手机聊天。长期托管可按 Hermes 自带网关服务说明配置；若该 profile 已有网关，应使用现有管理方式在合适时机重载，避免再启动第二个实例。

在手机聊天页选择相应在线设备并发送一条测试消息，收到实际回复才算聊天链路打通。设备在线只是连接状态，不能代替收发验证。

Windows 原生安装与配置路径按 [Hermes 官方说明](https://github.com/NousResearch/hermes-agent#quick-install) 和 [Orialis 插件的 Windows 示例](../integrations/hermes/orialis/README.md#macos--windows) 操作，连接变量含义相同。完整插件配置、附件要求和可选工作区见 [Hermes 集成文档](../integrations/hermes/orialis/README.md)。资讯发布 token、Pillow 视频依赖和屏幕记忆不是基础聊天部署的前置条件。

## 8. 备份、升级与回滚

仓库提供 `scripts/backup-restore.sh` 备份 SQLite 和上传内容。先创建私有备份根目录；每次备份使用新的子目录。下面暂停服务，以便数据库与附件目录在同一停写窗口保存：

```sh
sudo install -d -o root -g root -m 0700 /var/backups/orialis
orialis_backup="/var/backups/orialis/$(date +%Y%m%d-%H%M%S)"
sudo systemctl stop orialis
sudo bash scripts/backup-restore.sh backup \
  /var/lib/orialis/orialis.db \
  /var/lib/orialis/uploads \
  "$orialis_backup"
sudo install -o root -g root -m 0600 /etc/orialis.env "$orialis_backup/server.env"
sudo install -o root -g root -m 0755 /opt/orialis/bin/orialis-server "$orialis_backup/orialis-server"
sudo systemctl start orialis
```

确认脚本输出备份成功后再进行升级。备份中同时保留数据库、附件、环境配置和对应的旧二进制，宜另存到其他磁盘或主机。

升级时，先在源码目录获取并切换到目标 Release 标签，再重新执行第2节的 Linux 构建命令。按上面的步骤完成升级前备份，随后停服替换程序：

```sh
sudo install -o root -g root -m 0755 target/release/orialis-server /opt/orialis/bin/orialis-server.next
sudo systemctl stop orialis
sudo mv /opt/orialis/bin/orialis-server.next /opt/orialis/bin/orialis-server
sudo systemctl start orialis
sudo systemctl status orialis --no-pager
curl --fail-with-body -sS "https://${orialis_domain}/api/v1/health"
```

新程序启动时自动迁移数据库。若需要回到升级前状态，应把**同一份备份中的程序与数据一起恢复**；旧二进制不能直接撤销新数据库迁移。恢复会回到备份时刻，下面保留当前数据目录，以便核对备份之后的新增数据。

将 `orialis_backup` 设为你已验证的实际备份目录，确认其中存在上面保存的 `orialis-server`，然后从仓库根目录执行：

```sh
orialis_backup=/var/backups/orialis/替换为实际备份目录名
orialis_restore_stamp="$(date +%Y%m%d-%H%M%S)"
orialis_restore="/var/lib/orialis-restore-${orialis_restore_stamp}"
orialis_before_restore="/var/lib/orialis-before-restore-${orialis_restore_stamp}"
(
  set -e
  sudo test -f "$orialis_backup/orialis-server"
  sudo systemctl stop orialis
  sudo bash scripts/backup-restore.sh restore "$orialis_backup" "$orialis_restore"
  sudo mv "$orialis_restore/database.sqlite3" "$orialis_restore/orialis.db"
  sudo chown -R orialis:orialis "$orialis_restore"
  sudo chmod 0750 "$orialis_restore" "$orialis_restore/uploads"
  sudo mv /var/lib/orialis "$orialis_before_restore"
  sudo mv "$orialis_restore" /var/lib/orialis
  sudo install -o root -g root -m 0755 "$orialis_backup/orialis-server" /opt/orialis/bin/orialis-server
  sudo systemctl start orialis
  sudo systemctl status orialis --no-pager
)
curl --fail-with-body -sS "https://${orialis_domain}/api/v1/health"
```

恢复脚本先在新目录校验数据库和附件，成功后才切换路径。数据仍位于原模板的 `/var/lib/orialis`，因此无需改变 systemd 的写入权限范围。若本次升级也修改了配置，请另行比对备份中的 `server.env`；完整恢复行为见 [备份恢复说明](backup-restore.md)。

## 9. 常见故障

- **服务启动退出**：检查 `journalctl -u orialis`、环境文件权限、SQLite URL、目录写权限和端口。
- **生产拒绝启动**：确认 `ORIALIS_ENV=production` 且 `ORIALIS_DEV_DEVICE_AUTH=false`。
- **Nginx 502**：确认 systemd 正常且服务监听 `127.0.0.1:18443`。
- **Hermes 离线**：核对 WebSocket URL 路径、HTTPS 证书、两端 token、owner userId 和设备 ID。
- **设备在线但 APK 不显示**：检查 ID 是否为上述四个槽位之一；自定义槽位需要重建客户端并设置对应 dart-define。
- **Hermes 拒绝发送者**：将 `ORIALIS_ALLOWED_USERS` 精确设置为同一设备 ID 并重新加载 profile。
- **业务 API 返回 401**：Android Session 与 Hermes Agent Bearer token 不可互换；Android 需登录，Hermes 需配置 Agent token。

## 可选：部署 Web 客户端

先从 [Node.js 官方下载页](https://nodejs.org/en/download) 准备满足项目要求的 Node.js：建议使用受维护的 LTS 版本（如24），项目最低支持20.19或22.12。以下从仓库根目录执行：

```sh
cd web
npm ci
npm run build
cd ..
sudo install -d -o root -g root -m 0755 /srv/orialis-web
sudo cp -a web/dist/. /srv/orialis-web/
```

在 Orialis 的 HTTPS `server` 块中，保留已有专用 WebSocket/SSE 规则，**替换**最后的 `location /`，并新增通用 API 规则：

```nginx
root /srv/orialis-web;
index index.html;

location /api/ {
    proxy_pass http://127.0.0.1:18443;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_buffering off;
}

location / {
    try_files $uri $uri/ /index.html;
}
```

检查并应用后，浏览器访问同一 HTTPS 域名，用客户端的账号登录：

```sh
sudo nginx -t
sudo systemctl reload nginx
```

Web 静态资源和 `/api/` 使用同一来源；Vite 的开发代理不会被打包进静态文件。完整功能和限制见 [Web README](../web/README.md)。

## 说明与进一步资料

本指南的路径、变量、路由和命令入口已按仓库源码、部署模板与 Hermes CLI 核对；本次文档更新没有在空白服务器上重新执行完整部署。Rust 安装方式来自 [rustup](https://rustup.rs/)，Hermes 安装方式以其 [官方文档](https://github.com/NousResearch/hermes-agent) 为准。

开发者可继续阅读 [API 说明](api-v1.md)、[服务端架构](server-architecture.md) 和 [备份恢复细节](backup-restore.md)。
