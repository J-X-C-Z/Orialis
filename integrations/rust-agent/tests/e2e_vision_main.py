#!/usr/bin/env python3
"""Real fixed Orialis Server -> current Rust Agent -> explicit auxiliary vision.

Synthetic accounts, temporary PNG files, controlled local HTTP models only.
No deployment, real credentials, external providers or visual-quality claims.
"""
import argparse
import asyncio
import base64
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

import aiohttp
from aiohttp import web
from PIL import Image
from e2e_workspace import ROOT, port

TOKEN = "synthetic-vision-agent-token"
PRIMARY_KEY = "synthetic-primary-key-never-share"
VISION_KEY = "synthetic-separate-vision-key"
OWNER = "vision-owner"
DEVICE = "TE_ST_RustVision"


def api(base, method, path, body=None):
    request = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + TOKEN},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


async def main(args):
    checks, primary_calls, aux_calls, tool_receipts = [], [], [], []
    slow_started, slow_release = asyncio.Event(), asyncio.Event()
    with tempfile.TemporaryDirectory(prefix="orialis-native-vision-") as directory:
        root = Path(directory)
        binary = root / "agent"
        shutil.copy2(args.binary, binary)
        binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        image = Image.new("RGB", (128, 64), (255, 0, 0))
        image.paste((0, 0, 255), (64, 0, 128, 64))
        stream = io.BytesIO()
        image.save(stream, "PNG")
        png = stream.getvalue()

        async def primary(request):
            assert request.headers.get("Authorization") == "Bearer " + PRIMARY_KEY
            payload = await request.json()
            primary_calls.append(payload)
            assert payload["model"] == "controlled-primary"
            assert any(t["function"]["name"] == "vision_analyze" for t in payload["tools"])
            messages = payload["messages"]
            current = max(i for i, m in enumerate(messages) if m["role"] == "user")
            user = json.dumps(messages[current]["content"])
            label = re.search(r"vision-case-([a-z0-9-]+)", user).group(1)
            receipt = next((m for m in messages[current + 1:] if m["role"] == "tool"), None)
            if receipt:
                result = json.loads(receipt["content"])
                assert "base64" not in receipt["content"], receipt
                assert not result.get("_multimodal"), result
                tool_receipts.append((label, result))
                if result["success"]:
                    assert result["native_vision"] is False
                    assert result["meta"]["original_size"] == [128, 64], result
                    assert result["meta"]["crop"] == [4, 6, 124, 62], result
                    assert result["meta"]["sent_size"] == [120, 56], result
                    answer = "VISION_OK_" + label
                else:
                    answer = "VISION_ERROR_" + label
                message = {"role": "assistant", "content": answer}
                finish = "stop"
            else:
                handle = re.search(r"attachment:([A-Za-z0-9_-]+)", user).group(0)
                message = {
                    "role": "assistant", "content": None,
                    "tool_calls": [{"id": "call-" + label, "type": "function", "function": {
                        "name": "vision_analyze",
                        "arguments": json.dumps({"image_url": handle, "question": label, "region": [4, 6, 124, 62]}),
                    }}],
                }
                finish = "tool_calls"
            if payload.get("stream"):
                response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
                await response.prepare(request)
                delta = dict(message)
                if "tool_calls" in delta:
                    delta["tool_calls"] = [dict(c, index=i) for i, c in enumerate(delta["tool_calls"])]
                for chunk in [{"choices": [{"index": 0, "delta": delta, "finish_reason": None}]}, {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}]:
                    await response.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                await response.write(b"data: [DONE]\n\n")
                await response.write_eof()
                return response
            return web.json_response({"choices": [{"message": message, "finish_reason": finish}]})

        async def auxiliary(request):
            expected = None if request.path == "/aux-no-key" else "Bearer " + VISION_KEY
            assert request.headers.get("Authorization") == expected, dict(request.headers)
            assert request.headers.get("X-Orialis-Device-Id") is None
            payload = await request.json()
            aux_calls.append(payload)
            assert payload["model"] == "controlled-vision"
            serialized = json.dumps(payload)
            assert PRIMARY_KEY not in serialized and TOKEN not in serialized
            content = payload["messages"][1]["content"]
            prompt = content[0]["text"]
            data_url = content[1]["image_url"]["url"]
            assert data_url.startswith("data:image/png;base64,")
            decoded = Image.open(io.BytesIO(base64.b64decode(data_url.split(",", 1)[1], validate=True)))
            decoded.load()
            assert decoded.size == (120, 56)
            assert decoded.convert("RGB").getpixel((0, 0)) == (255, 0, 0)
            assert decoded.convert("RGB").getpixel((119, 55)) == (0, 0, 255)
            label = prompt.rsplit("\n\n", 1)[-1]
            if label == "cancel":
                slow_started.set()
                await slow_release.wait()
                text = "LATE VISION MUST NOT COMMIT"
            elif label == "empty":
                text = ""
            elif label == "failed":
                return web.json_response({"error": {"message": VISION_KEY}}, status=503)
            else:
                text = "Verified actual cropped red-blue image bytes."
            return web.json_response({"choices": [{"message": {"role": "assistant", "content": text}}]})

        app = web.Application(client_max_size=4 * 1024 * 1024)
        app.router.add_post("/main", primary)
        app.router.add_post("/aux", auxiliary)
        app.router.add_post("/aux-no-key", auxiliary)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        model_port = site._server.sockets[0].getsockname()[1]
        model_base = f"http://127.0.0.1:{model_port}"
        base = f"http://127.0.0.1:{port()}"
        env = os.environ.copy()
        for key in ["HERMES_VISION_API_KEY", "HERMES_CORE_API_KEY", "OPENAI_API_KEY"]:
            env.pop(key, None)
        env.update(
            ORIALIS_ENV="development", ORIALIS_HOST="127.0.0.1",
            ORIALIS_PORT=base.rsplit(":", 1)[1], ORIALIS_PUBLIC_URL=base,
            ORIALIS_DEV_DEVICE_AUTH="false", ORIALIS_DATABASE_URL=f"sqlite://{root}/server.sqlite?mode=rwc",
            ORIALIS_UPLOAD_DIR=str(root / "uploads"), ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,
            ORIALIS_AGENT_USER_ID=OWNER,
        )
        server_log, agent_log = (root / "server.log").open("w+"), (root / "agent.log").open("w+")
        server = subprocess.Popen([str(args.server)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
        agent = None
        command = [
            str(binary), "--server", base.replace("http", "ws") + "/api/v1/agent/ws",
            "--device", DEVICE, "--token", TOKEN, "--db", str(root / "agent.sqlite"),
            "--endpoint", model_base + "/main", "--model", "controlled-primary", "--api-key", PRIMARY_KEY,
            "--verify-owner", "--expected-owner", OWNER, "--session-context", "--attachments", "--vision-tools",
            "--vision-model", "controlled-vision",
        ]

        async def start(with_key=True):
            invocation = command + ["--vision-endpoint", model_base + ("/aux" if with_key else "/aux-no-key")]
            if with_key:
                invocation += ["--vision-api-key", VISION_KEY]
            process = subprocess.Popen(invocation, env=env, stdout=agent_log, stderr=subprocess.STDOUT)
            for _ in range(400):
                devices = await asyncio.to_thread(api, base, "GET", "/api/v1/agent/devices")
                if any(d["deviceId"] == DEVICE and d["online"] for d in devices["devices"]):
                    return process
                if process.poll() is not None:
                    agent_log.seek(0)
                    raise RuntimeError(agent_log.read())
                await asyncio.sleep(0.025)
            raise RuntimeError("Agent startup timed out")

        async def create(conversation):
            await asyncio.to_thread(api, base, "POST", "/api/v1/conversations", {"id": conversation, "title": "Synthetic vision"})
            await asyncio.to_thread(api, base, "PUT", f"/api/v1/conversations/{conversation}/agent-device", {"deviceId": DEVICE})
            form = aiohttp.FormData()
            form.add_field("files", png, filename="actual.png", content_type="image/png")
            async with aiohttp.ClientSession(headers={"Authorization": "Bearer " + TOKEN}) as http:
                async with http.post(base + f"/api/v1/conversations/{conversation}/attachments", data=form) as response:
                    value = await response.json()
                    assert response.status < 400, value
                    return value["items"]

        async def send(conversation, input_id, label, attachments=None):
            body = {"id": input_id, "content": label if label.startswith("/") else "vision-case-" + label}
            if attachments:
                body["attachments"] = attachments
            return await asyncio.to_thread(api, base, "POST", f"/api/v1/conversations/{conversation}/messages", body)

        async def finals(conversation, count=1):
            for _ in range(800):
                value = await asyncio.to_thread(api, base, "GET", f"/api/v1/conversations/{conversation}/messages?limit=500")
                found = [m for m in value["items"] if m["role"] == "assistant" and m["id"].startswith("final_")]
                if len(found) >= count:
                    return found
                if agent.poll() is not None:
                    agent_log.seek(0)
                    raise RuntimeError(agent_log.read())
                await asyncio.sleep(0.025)
            raise AssertionError({"missing_final": conversation, "messages": value})

        try:
            for _ in range(400):
                try:
                    await asyncio.to_thread(api, base, "GET", "/api/v1/health")
                    break
                except OSError:
                    await asyncio.sleep(0.025)
            with sqlite3.connect(root / "server.sqlite") as db:
                db.execute("INSERT INTO users(id,username,password_hash) VALUES(?,?,'synthetic-not-a-login')", (OWNER, OWNER))
            assert (await asyncio.to_thread(api, base, "GET", "/api/v1/auth/session"))["userId"] == OWNER
            agent = await start()
            attachments = await create("vision-normal")
            for n in range(3):
                label = "normal-" + str(n)
                await send("vision-normal", "normal-input-" + str(n), label, attachments)
                assert any(m["content"] == "VISION_OK_" + label for m in await finals("vision-normal", n + 1))
            checks += ["real bearer-verified owner, fixed Server HTTP upload and Agent WS tool chain", "three actual PNG attachment analyses used opaque aliases, crop normalization and a separate auxiliary model", "primary and auxiliary models received only their explicitly configured credentials"]
            before = len(aux_calls)
            await send("vision-normal", "over-budget", "over-budget", attachments)
            assert any(m["content"] == "VISION_ERROR_over-budget" for m in await finals("vision-normal", 4))
            assert len(aux_calls) == before
            await send("vision-normal", "reset-command", "/new")
            await finals("vision-normal", 5)
            await send("vision-normal", "after-reset", "after-reset", attachments)
            assert any(m["content"] == "VISION_OK_after-reset" for m in await finals("vision-normal", 6))
            assert len(aux_calls) == before + 1
            checks.append("fourth same-image analysis was refused; /new reset the epoch budget and accepted the same image")

            # Fault-inject a real server redelivery of the completed input. The
            # fixed Server pumps this durable row through the normal Agent WS.
            before_primary, before_aux = len(primary_calls), len(aux_calls)
            agent.terminate()
            agent.wait(timeout=5)
            agent = None
            server.terminate()
            server.wait(timeout=5)
            with sqlite3.connect(root / "server.sqlite") as db:
                db.execute("INSERT INTO agent_delivery_queue(message_id,user_id,conversation_id,attempts,next_attempt_at) VALUES('after-reset',?,'vision-normal',0,'2000-01-01T00:00:00Z')", (OWNER,))
            server = subprocess.Popen([str(args.server)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
            for _ in range(400):
                try:
                    await asyncio.to_thread(api, base, "GET", "/api/v1/health")
                    break
                except OSError:
                    await asyncio.sleep(0.025)
            agent = await start()
            for _ in range(800):
                with sqlite3.connect(root / "server.sqlite") as db:
                    pending = db.execute("SELECT COUNT(*) FROM agent_delivery_queue WHERE message_id='after-reset'").fetchone()[0]
                if pending == 0:
                    break
                await asyncio.sleep(0.025)
            assert pending == 0, "Server did not replay the synthetic delivery"
            assert (len(primary_calls), len(aux_calls)) == (before_primary, before_aux)
            assert len(await finals("vision-normal", 6)) == 6
            checks.append("fixed Server/Agent restart plus fault-injected completed-input redelivery reused the durable journal without either model call")

            for label in ["empty", "failed"]:
                media = await create("vision-" + label)
                before = len(aux_calls)
                await send("vision-" + label, "input-" + label, label, media)
                assert (await finals("vision-" + label))[0]["content"] == "VISION_ERROR_" + label
                assert len(aux_calls) == before + 1
                result = next(result for name, result in tool_receipts if name == label)
                assert VISION_KEY not in json.dumps(result)
            checks.append("empty and HTTP-error vision responses produced truthful failed receipts, no secret echoes and no retries")

            media = await create("vision-cancel")
            await send("vision-cancel", "cancel-input", "cancel", media)
            await asyncio.wait_for(slow_started.wait(), 10)
            before = time.monotonic()
            await send("vision-cancel", "stop-command", "/stop")
            stopped = await finals("vision-cancel", 2)
            assert time.monotonic() - before < 5
            assert any("已取消" in m["content"] for m in stopped), stopped
            slow_release.set()
            await asyncio.sleep(0.2)
            with sqlite3.connect(root / "agent.sqlite") as db:
                assert db.execute("SELECT COUNT(*) FROM messages WHERE body LIKE '%LATE VISION MUST NOT COMMIT%'").fetchone()[0] == 0
            await send("vision-cancel", "after-cancel", "after-cancel-ok", media)
            assert any(m["content"] == "VISION_OK_after-cancel-ok" for m in await finals("vision-cancel", 3))
            checks.append("/stop cancelled an in-flight auxiliary vision request, excluded its late result and released resources for a later request")

            agent.terminate()
            agent.wait(timeout=5)
            agent = None
            await asyncio.sleep(0.2)
            agent = await start(with_key=False)
            media = await create("vision-anonymous")
            await send("vision-anonymous", "anonymous-input", "anonymous", media)
            assert (await finals("vision-anonymous"))[0]["content"] == "VISION_OK_anonymous"
            checks.append("explicit auxiliary endpoint without a vision key received no Authorization header, never the configured primary key")
            with sqlite3.connect(root / "agent.sqlite") as db:
                raw = " ".join(row[0] for row in db.execute("SELECT body FROM messages"))
                assert "data:image/" not in raw and PRIMARY_KEY not in raw and VISION_KEY not in raw and TOKEN not in raw
            checks.append("durable chat retained attachment references and textual analysis, not image base64 or credentials")
        except Exception:
            agent_log.seek(0)
            server_log.seek(0)
            print("AGENT LOG", agent_log.read())
            print("SERVER LOG", server_log.read()[-6000:])
            raise
        finally:
            slow_release.set()
            if agent:
                agent.terminate()
                agent.wait(timeout=5)
            server.terminate()
            server.wait(timeout=5)
            await runner.cleanup()
        result = {
            "passed": len(checks), "checks": checks, "primary_calls": len(primary_calls), "auxiliary_calls": len(aux_calls),
            "binary_sha256": binary_hash, "server_sha256": hashlib.sha256(args.server.read_bytes()).hexdigest(),
            "limitations": "Synthetic owner and controlled local model responses; real fixed Server/current Agent, actual uploaded/cropped pixels and lifecycle. No external provider quality claim or production deployment.",
        }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / "hermes-rust-core/target/debug/orialis_agent")
    parser.add_argument("--server", type=Path, default=ROOT / "orialis/target/release/orialis-server")
    parser.add_argument("--out", type=Path, default=ROOT / "hermes-rust-core/results/vision-main-e2e.json")
    asyncio.run(main(parser.parse_args()))
