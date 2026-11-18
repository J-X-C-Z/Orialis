# Orialis Rust Agent

The Rust Agent runs separately from the Orialis API. It connects as an account-bound device and provides model-backed chat, conversation context, Orialis tools, attachments, MCP tools, and scheduled reports.

## Build and configure

From the repository root, build with the package's lockfile:

```sh
cargo build --release --locked --manifest-path integrations/rust-agent/Cargo.toml --bin orialis_agent
```

On Linux, install the resulting binary at `/opt/orialis-agent/bin/orialis_agent` and install Poppler (`pdftotext`). The [systemd template](deploy/orialis-agent.service) uses the `hermes` system account. Create `/var/lib/orialis-agent` owned by that account and set permissions to `0750`. Copy the [environment example](deploy/orialis-agent.env.example) to `/etc/orialis-agent.env`, set permissions to `0600`, and configure the enrolled device, model endpoint and credentials. Install the [MCP example](deploy/orialis-agent-mcp.example.json) as `/etc/orialis-agent-mcp.json` and remove entries you don't use. Install the service and enable it with `systemctl enable --now orialis-agent.service` after reloading systemd. Confirm the device appears online in Orialis before selecting it.

Use a stable `ORIALIS_SERVER_URL`. The agent binds its state to this gateway origin, account and device. Set `ORIALIS_ATTACHMENT_ORIGIN` to the trusted origin used in attachment URLs if the gateway uses a private address. This keeps exact origin and attachment ID checks in place. Add `--chat-images` to the service arguments after confirming your configured model accepts image input. See [attachment support](ATTACHMENTS.md) and [MCP configuration](MCP.md).

## Windows hub and morning report

Configure `windows-mcp` in the service account's SSH config with a private route, a dedicated identity, and strict host key checking. The MCP entry runs the Windows wrapper directly. The refresh script uses the separate hub HTTP listener on **Windows loopback** at `127.0.0.1:8765`. Configure that listener to start in the Windows account with access to the hub's local sources.

Install [hub-sync.sh](deploy/hub-sync.sh) in `/opt/orialis-agent/bin`. Install the [refresh service](deploy/orialis-hub-refresh.service) and [timer](deploy/orialis-hub-refresh.timer). After reloading systemd, run the service once and inspect its journal. An HTTP 200 confirms the trigger was accepted. Check source status for freshness and partial refreshes before relying on the index. Enable the timer with `systemctl enable --now orialis-hub-refresh.timer` for daily 06:50 Asia/Shanghai refreshes.

In the intended Orialis conversation, ask the agent to create a `cronjob_manage` job with `schedule` set to `0 7 * * *`, `timezone` to `Asia/Shanghai`, and `deliver` to `origin`. Approve the proposed job in that conversation. The prompt should check index freshness, gather the requested notices and Orialis tasks, and report failed reads explicitly. After checking the new schedule and its target, pause the predecessor schedule. A delivery receipt confirms server acceptance. Verify presentation separately in a connected client.
