#!/usr/bin/env python3
"""Rust-generated lifecycle frames -> original Python parser -> real server.

All services and clients are children of this one invocation. Uses temporary
synthetic data and a local test token. This is transport/sequence verification,
not a live-model or production/mobile visual test. No fake event validator.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

import websockets

ROOT = Path(__file__).resolve().parents[2]
CRATE = ROOT / "hermes-rust-core"
SHA = "f9a064bf05b18265afd26905e7240777d4ce355c"


def api(base, method, path, body=None):
    request = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={"Content-Type": "application/json", "x-orialis-device-id": "event-contract-client"},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


async def main(args):
    checkout = args.orialis.resolve()
    assert subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip() == SHA
    spec = importlib.util.spec_from_file_location("original_orialis_protocol", checkout / "integrations/hermes/orialis/protocol.py")
    original = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(original)
    checks = []
    with tempfile.TemporaryDirectory(prefix="orialis-event-contract-") as temporary:
        directory = Path(temporary)
        fixture = directory / "frames.json"
        env = os.environ.copy()
        env.update(CARGO_HOME=str(ROOT / ".toolchain/cargo"), RUSTUP_HOME=str(ROOT / ".toolchain/rustup"), EVENT_CONTRACT_FIXTURE=str(fixture))
        env["PATH"] = str(ROOT / ".toolchain/cargo/bin") + os.pathsep + env["PATH"]
        subprocess.run(["cargo", "test", "--manifest-path", str(CRATE / "Cargo.toml"), "--test", "gateway_events", "export_contract_fixture", "--", "--exact"], env=env, check=True)
        frames = json.loads(fixture.read_text())
        for frame in frames:
            assert original.parse_message(original.encode(frame)) == frame
        checks.append(f"{len(frames)} Rust-generated lifecycle frames pass unchanged original Python parser")
        assert {f["type"] for f in frames} == {"agent.start", "agent.typing", "agent.delta", "agent.complete", "agent.error", "tool.started", "tool.completed", "tool.failed"}
        checks.append("all eight advertised event capabilities exercised")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        token = "synthetic-local-event-contract-token"
        env.update(ORIALIS_ENV="development", ORIALIS_HOST="127.0.0.1", ORIALIS_PORT=str(port), ORIALIS_PUBLIC_URL=base,
                   ORIALIS_DEV_DEVICE_AUTH="1", ORIALIS_DATABASE_URL=f"sqlite://{directory}/server.sqlite?mode=rwc",
                   ORIALIS_UPLOAD_DIR=str(directory / "uploads"), ORIALIS_AGENT_DEVICE_TOKEN=token)
        binary = args.server_binary.resolve()
        log = (directory / "server.log").open("w+")
        server = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while True:
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f"server exited: {log.read()}")
                try:
                    await asyncio.to_thread(api, base, "GET", "/api/v1/health")
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise
                    await asyncio.sleep(.03)
            await asyncio.to_thread(api, base, "GET", "/api/v1/conversations")
            url = base.replace("http://", "ws://") + "/api/v1/agent/ws"
            capabilities = sorted({f["type"] for f in frames})

            async def receive(ws, kind):
                while True:
                    value = json.loads(await asyncio.wait_for(ws.recv(), 10))
                    if value["type"] == "ping":
                        await ws.send(json.dumps({"version": 1, "type": "pong"}))
                        continue
                    assert value["type"] == kind, (kind, value)
                    return value

            async def connect():
                ws = await websockets.connect(url, additional_headers={"Authorization": f"Bearer {token}"})
                await ws.send(original.encode(original.hello("TE_ST_Rust", platform="linux", capabilities=capabilities)))
                hello = await receive(ws, "hello_ack")
                assert set(capabilities) <= original.capabilities_from_ack(hello)
                await ws.send(original.encode(original.capabilities_hello(capabilities, resume_from=0)))
                cap_ack = await receive(ws, "capabilities.ack")
                assert cap_ack["next_seq"] == 1
                return ws

            ws = await connect()
            try:
                for conversation in ["contract-conversation", "other-conversation"]:
                    await asyncio.to_thread(api, base, "POST", "/api/v1/conversations", {"id": conversation, "title": "Synthetic event contract"})
                    await asyncio.to_thread(api, base, "PUT", f"/api/v1/conversations/{conversation}/agent-device", {"deviceId": "TE_ST_Rust"})
                await asyncio.to_thread(api, base, "POST", "/api/v1/conversations/contract-conversation/messages", {"id": "input-contract-conversation", "content": "Synthetic lifecycle request"})
                incoming = await receive(ws, "message.send")
                assert incoming["message_id"] == "input-contract-conversation"
                await ws.send(original.encode({"version": 1, "type": "message.ack", "message_id": incoming["message_id"], "status": "received"}))
                await ws.send(original.encode(frames[0]))
                assert (await receive(ws, "agent.ack"))["status"] == "received"
                await ws.send(original.encode(frames[2]))
                gap = await receive(ws, "agent.ack")
                assert gap["status"] == "gap" and gap["expected_seq"] == 2
                checks.append("real release server detects deliberate device-sequence gap and returns expected_seq")
                for frame in frames[1:]:
                    if frame["type"] == "agent.complete":
                        reply = {"version": 1, "type": "message.reply", "message_id": frame["message_id"], "reply_to": incoming["message_id"], "conversation_id": incoming["conversation_id"], "content": frame["content"]}
                        await ws.send(original.encode(reply))
                        receipt = await receive(ws, "message.ack")
                        assert receipt["message_id"] == frame["message_id"] and receipt["status"] == "received"
                        stored = await asyncio.to_thread(api, base, "GET", "/api/v1/conversations/contract-conversation/messages?limit=500")
                        assert any(m["id"] == frame["message_id"] and m["content"] == frame["content"] and m["role"] == "assistant" for m in stored["items"])
                        checks.append("completion message_id points to actual server-persisted final reply after message.ack")
                    await ws.send(original.encode(frame))
                    receipt = await receive(ws, "agent.ack")
                    assert receipt["event_id"] == frame["event_id"] and receipt["seq"] == frame["seq"] and receipt["status"] == "received", receipt
                checks.append("all event types accepted through actual release server parser and event registry")
            finally:
                await ws.close()
            ws = await connect()
            try:
                for frame in frames:
                    await ws.send(original.encode(frame))
                    receipt = await receive(ws, "agent.ack")
                    assert receipt["status"] == "duplicate" and receipt["event_id"] == frame["event_id"] and receipt["seq"] == frame["seq"]
                checks.append("reconnected identical ID/seq replay recognized as duplicate for every event")
                # Parser rejects a malformed event rather than accepting a JSON
                # shape alone; no sequence can be consumed by this invalid frame.
                invalid = dict(frames[-1], event_id="invalid-zero-seq", seq=0)
                await ws.send(json.dumps(invalid))
                error = await receive(ws, "error")
                assert error["code"] == "INVALID_MESSAGE"
                checks.append("real release server rejects zero event sequence")
            finally:
                await ws.close()
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
            log.close()
        report = {"scope": "Rust actor-generated frames, original Python parser, unchanged real release Orialis Server; synthetic local data, no model or mobile UI quality claim", "orialis_sha": SHA, "server_binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "frames": len(frames), "checks_passed": len(checks), "checks": checks}
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--orialis", type=Path, default=ROOT / "orialis")
    parser.add_argument("--server-binary", type=Path, default=ROOT / "orialis/target/release/orialis-server")
    parser.add_argument("--out", type=Path)
    asyncio.run(main(parser.parse_args()))
