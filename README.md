# Oris

Oris（Orialis）当前从纯服务端基础开始建设。`oris-refactor` 分支只保留 Oris 自己的代码；方寸完整项目保存在 [`fangcun-backup`](https://github.com/J-X-C-Z/Orialis/tree/fangcun-backup)，后续按需抽取，不直接整体复制。

## 当前范围

- Rust workspace：`oris-core` + `oris-server`
- 纯 JSON API，无网页、PWA、静态资源和业务数据层
- 健康检查、服务元信息、能力发现
- 环境变量配置，默认监听 `127.0.0.1:18443`
- 生产公网地址预留为 `https://orialis.jxcz.top`

API：

```text
GET /api/health
GET /api/v1/meta
GET /api/v1/capabilities
```

## 本地运行

需要 Rust stable：

```bash
cargo run -p oris-server
```

自定义配置：

```bash
ORIS_HOST=127.0.0.1 \
ORIS_PORT=18443 \
ORIS_ENV=development \
ORIS_PUBLIC_URL=https://orialis.jxcz.top \
cargo run -p oris-server
```

验证：

```bash
curl http://127.0.0.1:18443/api/health
curl http://127.0.0.1:18443/api/v1/meta
```

## 域名准备

部署时将 `orialis.jxcz.top` 的 DNS A/AAAA 记录指向服务器公网地址，服务器本机服务保持监听 `127.0.0.1:18443`，由 Nginx 负责 HTTPS 终止和反向代理。配置模板见 [`deploy/nginx/orialis.jxcz.top.conf.example`](deploy/nginx/orialis.jxcz.top.conf.example)，systemd 模板见 [`deploy/oris.service`](deploy/oris.service)。

当前不包含 DNS 修改、证书申请或远程服务器发布。

