# DSH 历史适配与部署参考

当前 Orialis 的实际执行入口已统一为 Hermes；本目录源码和下面的部署记录作为历史适配参考保留，不启用旧 DSH 服务或默认路由。当前 bridge.mjs 比下面2026-10-23的初始实现增加了状态、delta、取消和回复回执等能力，以现有源码及测试为准。配置示例不含真实凭据。

`dsh/` 的配置补丁、wrapper 和 `systemd/` 服务样例来自该历史部署；其中具体路径、用户与本机代理地址不能当成新环境的已验证部署配置。下文原记录保留其当时范围，不代表当前生产执行状态。

---

# Orialis DSH Bridge

This integration connects a DeepSeek Harness ACP profile to the Orialis Agent
Gateway. Orialis owns conversations and message persistence; DSH owns the
assistant session and model execution.

## Scope

- Text messages only.
- One persistent DSH session per Orialis conversation while the bridge process is
  running.
- Baseline `hello`, `hello_ack`, `ping`, `pong`, `message.send`, `message.ack`,
  and `message.reply` frames.
- Attachments, tool approvals, streaming events, and proactive delivery are not
  exposed in v1. DSH tool permission requests are denied fail-closed.

## Configuration

Required environment variables:

| Variable | Description |
| --- | --- |
| `ORIALIS_SERVER_URL` | Agent Gateway URL, normally `wss://orialis.jxcz.top/api/v1/agent/ws` |
| `ORIALIS_DEVICE_ID` | Stable `<USER>_<DEVICE>_<Agent>` ID, for example `JXCZ_HAKARI_DSH` |
| `ORIALIS_DEVICE_TOKEN` | Account-bound Orialis Agent token |

Optional variables:

| Variable | Default | Description |
| --- | --- | --- |
| `DSH_COMMAND` | `dsh` | DSH executable |
| `DSH_PROFILE` | `acp` | DSH ACP profile |
| `DSH_CWD` | `/var/lib/orialis-dsh/workspace` | ACP session workspace |
| `DSH_REQUEST_TIMEOUT_MS` | `900000` | Per-prompt timeout |

## Development

```sh
npm install
npm test
```

## Deployment

Use [systemd/orialis-dsh-bridge.service](systemd/orialis-dsh-bridge.service) and
keep the token in `/etc/orialis-dsh-bridge.env` with mode `0600`.

```sh
npm install --omit=dev
systemctl daemon-reload
systemctl enable --now orialis-dsh-bridge.service
```

## Westlake profile

The Hakari deployment defaults to `westlake-hpc/deepseek-flash` through the loopback HPC relay at
`http://127.0.0.1:18777/v1`.

1. Install [dsh/home-cordis.patch.yml](dsh/home-cordis.patch.yml) as
   `/root/.dsh/cordis.patch.yml`.
2. Install [dsh/acp-cordis.patch.yml](dsh/acp-cordis.patch.yml) as
   `/root/.dsh/profiles/acp/cordis.patch.yml`.
3. Install [dsh/dsh-wrapper.sh](dsh/dsh-wrapper.sh) as `/usr/local/bin/dsh` and
   keep the package launcher at `/usr/local/bin/dsh-bin`.
4. Create `/etc/dsh/westlake.env` from
   [dsh/westlake.env.example](dsh/westlake.env.example) with mode `0640`.

The HPC relay must bind its upstream HTTPS connection to the physical campus
interface. Otherwise Clash TUN can intercept the campus-only
`hpc-api.westlake.edu.cn` address and the relay returns `upstream unavailable`.
