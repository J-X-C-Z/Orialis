#!/usr/bin/env python3
"""Actual fixed Server -> main Rust Agent -> bounded native children.
Synthetic owner, temporary files, controlled local HTTP model only. No paid API.
"""
import argparse
import asyncio
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path
from aiohttp import web
from e2e_local_main import api, TOKEN
from e2e_workspace import ROOT, port


async def main(args):
    checks, calls, child_calls, outcomes = [], [], [], {}
    slow_started, slow_release = asyncio.Event(), asyncio.Event()
    inherited = False
    with tempfile.TemporaryDirectory(prefix="orialis-delegation-main-") as directory:
        root = Path(directory)
        binary = root / "agent"
        shutil.copy2(args.binary, binary)
        workspace = root / "workspace"
        workspace.mkdir()
        (workspace / "fixture.txt").write_text("Actual delegated file read 中文\n")
        async def model(request):
            payload = await request.json()
            calls.append(payload)
            assert request.headers.get("Authorization") == "Bearer synthetic-delegation-model-key"
            messages = payload["messages"]
            is_child = messages[0]["content"].startswith("You are an isolated delegated assistant.")
            names = {entry["function"]["name"] for entry in payload["tools"]}
            at = max(i for i, m in enumerate(messages) if m["role"] == "user")
            user = messages[at]["content"]
            receipts = [m for m in messages[at + 1:] if m["role"] == "tool"]
            if is_child:
                child_calls.append(payload)
                label, side = re.search(r"CHILD:([a-z0-9-]+):(left|right):END", user).groups()
                serialized = json.dumps(messages)
                assert "PARENT_PRIVATE_MARKER" not in serialized
                assert ("LEFT_ONLY_CONTEXT" in serialized) == (side == "left")
                assert ("RIGHT_ONLY_CONTEXT" in serialized) == (side == "right")
                assert names == ({"read_file", "list_tasks"} if inherited else set()), names
                if label == "slow":
                    slow_started.set()
                    await slow_release.wait()
                    message = {"role": "assistant", "content": "LATE CHILD MUST NOT COMMIT"}
                elif inherited and not receipts:
                    tool = "list_tasks" if side == "left" else "read_file"
                    arguments = {} if side == "left" else {"path": "fixture.txt"}
                    message = {"role": "assistant", "content": None, "tool_calls": [{"id": f"child-{label}-{side}", "type": "function", "function": {"name": tool, "arguments": json.dumps(arguments)}}]}
                else:
                    if inherited:
                        result = json.loads(receipts[-1]["content"])
                        if side == "left":
                            assert result["ok"] is True, result
                            assert any(t["title"] == "Actual delegated domain task" for t in result["result"]["items"]), result
                        else:
                            assert "Actual delegated file read 中文" in result["content"], result
                            assert result["complete_read"] is True
                    message = {"role": "assistant", "content": f"CHILD_OK_{label}_{side}"}
            else:
                label = re.search(r"DELEGATECASE:([a-z0-9-]+):END", user).group(1)
                assert "delegate_task" in names
                schema = next(t["function"] for t in payload["tools"] if t["function"]["name"] == "delegate_task")
                assert "action" not in schema["parameters"]["properties"]
                assert "images" not in schema["parameters"]["properties"]["tasks"]["items"]["properties"]
                if not receipts:
                    sides = ["left"] if label == "slow" else ["left", "right"]
                    tasks = [{"goal": f"CHILD:{label}:{side}:END", "context": f"{side.upper()}_ONLY_CONTEXT"} for side in sides]
                    message = {"role": "assistant", "content": None, "tool_calls": [{"id": "delegate-" + label, "type": "function", "function": {"name": "delegate_task", "arguments": json.dumps({"tasks": tasks})}}]}
                else:
                    assert label != "slow", "Cancelled child result reached parent model"
                    result = json.loads(receipts[-1]["content"])
                    outcomes[label] = result
                    assert result["mode"] == "inline" and result["partial"] is False, result
                    assert [r["summary"] for r in result["results"]] == [f"CHILD_OK_{label}_left", f"CHILD_OK_{label}_right"], result
                    assert len({r["subagent_id"] for r in result["results"]}) == 2
                    message = {"role": "assistant", "content": "DELEGATION_OK_" + label}
            finish = "tool_calls" if message.get("tool_calls") else "stop"
            if not payload.get("stream"):
                return web.json_response({"choices": [{"message": message, "finish_reason": finish}]})
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await response.prepare(request)
            delta = dict(message)
            if "tool_calls" in delta:
                delta["tool_calls"] = [dict(call, index=i) for i, call in enumerate(delta["tool_calls"])]
            for chunk in [{"choices": [{"index": 0, "delta": delta, "finish_reason": None}]}, {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}]:
                await response.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            await response.write(b"data: [DONE]\n\n")
            await response.write_eof()
            return response

        app = web.Application(client_max_size=4 * 1024 * 1024)
        app.router.add_post("/v1/chat/completions", model)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        model_port = site._server.sockets[0].getsockname()[1]
        base = f"http://127.0.0.1:{port()}"
        env = os.environ.copy()
        for key in ["HERMES_CORE_API_KEY", "OPENAI_API_KEY"]:
            env.pop(key, None)
        env.update(ORIALIS_ENV="development", ORIALIS_HOST="127.0.0.1", ORIALIS_PORT=base.rsplit(":", 1)[1], ORIALIS_PUBLIC_URL=base, ORIALIS_DEV_DEVICE_AUTH="false", ORIALIS_DATABASE_URL=f"sqlite://{root}/server.sqlite?mode=rwc", ORIALIS_UPLOAD_DIR=str(root / "uploads"), ORIALIS_AGENT_DEVICE_TOKEN=TOKEN, ORIALIS_AGENT_USER_ID="full-owner")
        server_log, agent_log = (root / "server.log").open("w+"), (root / "agent.log").open("w+")
        server = subprocess.Popen([str(args.server)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
        agent = None
        command = [str(binary), "--server", base.replace("http", "ws") + "/api/v1/agent/ws", "--device", "TE_ST_RustDelegation", "--token", TOKEN, "--db", str(root / "agent.sqlite"), "--endpoint", f"http://127.0.0.1:{model_port}/v1/chat/completions", "--api-key", "synthetic-delegation-model-key", "--verify-owner", "--expected-owner", "full-owner", "--session-context", "--delegation", "--stream-events", "--interactions", "--domain-tools", "--local-tools-json", json.dumps({"root": str(workspace), "write": "deny", "execute": "deny"})]
        async def health():
            for _ in range(400):
                try:
                    await asyncio.to_thread(api, base, "GET", "/api/v1/health")
                    return
                except OSError:
                    await asyncio.sleep(.025)
            raise AssertionError("Server startup timed out")
        async def start():
            process = subprocess.Popen(command + (["--delegate-tools", "list_tasks,read_file"] if inherited else []), env=env, stdout=agent_log, stderr=subprocess.STDOUT)
            for _ in range(400):
                devices = await asyncio.to_thread(api, base, "GET", "/api/v1/agent/devices")
                if any(d["deviceId"] == "TE_ST_RustDelegation" and d["online"] for d in devices["devices"]):
                    return process
                if process.poll() is not None:
                    agent_log.seek(0)
                    raise AssertionError(agent_log.read())
                await asyncio.sleep(.025)
            raise AssertionError("Agent startup timed out")
        async def create(conversation):
            await asyncio.to_thread(api, base, "POST", "/api/v1/conversations", {"id": conversation, "title": "Synthetic delegation"})
            await asyncio.to_thread(api, base, "PUT", f"/api/v1/conversations/{conversation}/agent-device", {"deviceId": "TE_ST_RustDelegation"})
        async def send(conversation, mid, content):
            return await asyncio.to_thread(api, base, "POST", f"/api/v1/conversations/{conversation}/messages", {"id": mid, "content": content})
        async def finals(conversation, count):
            for _ in range(800):
                messages = await asyncio.to_thread(api, base, "GET", f"/api/v1/conversations/{conversation}/messages?limit=500")
                found = [m for m in messages["items"] if m["role"] == "assistant" and m["id"].startswith("final_")]
                if len(found) >= count:
                    return found
                assert agent is not None and agent.poll() is None, "Agent exited"
                await asyncio.sleep(.025)
            raise AssertionError(("Missing final", conversation, count, messages, outcomes))
        async def run_case(conversation, label, count):
            await send(conversation, "input-" + label, f"DELEGATECASE:{label}:END PARENT_PRIVATE_MARKER")
            result = await finals(conversation, count)
            assert any(m["content"] == "DELEGATION_OK_" + label for m in result), result
        async def stop_agent():
            nonlocal agent
            agent.terminate()
            assert await asyncio.to_thread(agent.wait, 5) == 0
            agent = None
            await asyncio.sleep(.2)
        try:
            await health()
            with sqlite3.connect(root / "server.sqlite") as db:
                db.execute("INSERT INTO users(id,username,password_hash) VALUES('full-owner','full-owner','synthetic-no-login')")
            await asyncio.to_thread(api, base, "POST", "/api/v1/tasks", {"title": "Actual delegated domain task"})
            agent = await start()
            await create("delegate-default")
            await run_case("delegate-default", "default", 1)
            checks.append("actual main Agent opt-in inline delegation executes two isolated child model contexts with zero inherited tools by default")
            before = (len(calls), len(child_calls))
            await send("delegate-default", "input-default", "DELEGATECASE:default:END PARENT_PRIVATE_MARKER")
            await asyncio.sleep(.2)
            assert (len(calls), len(child_calls)) == before
            checks.append("same HTTP input ID does not repeat parent/child calls")
            await stop_agent()
            inherited = True
            agent = await start()
            await create("delegate-tools")
            await run_case("delegate-tools", "tools", 1)
            checks.append("explicit list_tasks/read_file inheritance performs actual authenticated Server and confined filesystem reads, with separate child contexts")
            before = (len(calls), len(child_calls))
            await stop_agent()
            server.terminate()
            await asyncio.to_thread(server.wait, 5)
            with sqlite3.connect(root / "server.sqlite") as db:
                db.execute("INSERT INTO agent_delivery_queue(message_id,user_id,conversation_id,attempts,next_attempt_at) VALUES('input-tools','full-owner','delegate-tools',0,'2000-01-01T00:00:00Z')")
            server = subprocess.Popen([str(args.server)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
            await health()
            agent = await start()
            for _ in range(500):
                with sqlite3.connect(root / "server.sqlite") as db:
                    pending = db.execute("SELECT count(*) FROM agent_delivery_queue WHERE message_id='input-tools'").fetchone()[0]
                if pending == 0:
                    break
                await asyncio.sleep(.025)
            assert pending == 0
            assert (len(calls), len(child_calls)) == before
            checks.append("actual Server/Agent restart and durable delivery replay reuse the committed result without parent, child or inherited-tool execution")
            await create("delegate-cancel")
            await send("delegate-cancel", "input-slow", "DELEGATECASE:slow:END PARENT_PRIVATE_MARKER")
            await asyncio.wait_for(slow_started.wait(), 10)
            started = time.monotonic()
            await send("delegate-cancel", "stop-command", "/stop")
            stopped = await finals("delegate-cancel", 2)
            stop_seconds = time.monotonic() - started
            assert stop_seconds < 5 and any("已取消" in m["content"] for m in stopped), stopped
            slow_release.set()
            await asyncio.sleep(.2)
            with sqlite3.connect(root / "agent.sqlite") as db:
                assert db.execute("SELECT count(*) FROM messages WHERE body LIKE '%LATE CHILD MUST NOT COMMIT%'").fetchone()[0] == 0
            await run_case("delegate-cancel", "after-stop", 3)
            checks.append("/stop cancels a demonstrably in-flight child, suppresses late completion, and permits later child work")
            await send("delegate-tools", "reset-command", "/new")
            await finals("delegate-tools", 2)
            await run_case("delegate-tools", "after-new", 3)
            with sqlite3.connect(root / "agent.delegation.sqlite") as db:
                rows = db.execute("SELECT id,parent,depth,generation,status,task,messages FROM delegation_children").fetchall()
                assert any(row[3] > 0 for row in rows)
                assert any(row[4] == "interrupted" for row in rows)
                receipts = db.execute("SELECT count(*) FROM delegation_receipts WHERE status='completed'").fetchone()[0]
                assert receipts >= 6, receipts
                assert all("PARENT_PRIVATE_MARKER" not in row[6] for row in rows)
            checks.append("/new advances durable parent generation; child lineage/transcripts and completed inherited-tool receipts remain private and isolated")
            await stop_agent()
            for index, names in enumerate(["unknown_tool", "memory", "vision_analyze", "list_tasks,list_tasks"]):
                invocation = list(command)
                invocation[invocation.index("--db") + 1] = str(root / f"invalid-{index}.sqlite")
                invocation += ["--delegate-tools", names]
                process = await asyncio.create_subprocess_exec(*invocation, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
                stdout, _ = await asyncio.wait_for(process.communicate(), 10)
                assert process.returncode != 0, (names, stdout.decode())
                assert b"delegation tool" in stdout or b"inherited delegation" in stdout, stdout.decode()
            checks.append("unknown, permanently forbidden, unavailable and duplicate inherited tool selections all fail main startup")
        except Exception:
            agent_log.seek(0)
            server_log.seek(0)
            print("AGENT LOG", agent_log.read())
            print("SERVER LOG", server_log.read()[-5000:])
            raise
        finally:
            slow_release.set()
            if agent:
                agent.terminate()
                await asyncio.to_thread(agent.wait, 5)
            server.terminate()
            await asyncio.to_thread(server.wait, 5)
            await runner.cleanup()
        result = {"passed": len(checks), "checks": checks, "provider_calls": len(calls), "child_provider_calls": len(child_calls), "stop_seconds": stop_seconds, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "server_sha256": hashlib.sha256(args.server.read_bytes()).hexdigest(), "limitations": "Synthetic owner and controlled local provider only. Actual fixed Server/current main Agent, isolated children and real read tools. HTTP duplicate ingress plus forced Server replay tested; uncertain-effect crash replay separately covered by Rust runtime tests. No paid-provider quality or production deployment claim."}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=ROOT / "hermes-rust-core/target/debug/orialis_agent")
    parser.add_argument("--server", type=Path, default=ROOT / "orialis/target/release/orialis-server")
    parser.add_argument("--out", type=Path, default=ROOT / "hermes-rust-core/results/delegation-main-e2e.json")
    asyncio.run(main(parser.parse_args()))
