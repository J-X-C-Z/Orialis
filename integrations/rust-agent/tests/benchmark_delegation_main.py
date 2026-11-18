#!/usr/bin/env python3
"""Actual Server/main Agent delegation benchmark. Synthetic local provider only.

Write-only preparation does not run this benchmark. Run explicitly with a frozen
Agent binary in a quiet window. No Cargo, external models, or baseline inference.
"""
import argparse
import asyncio
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

import aiohttp
from aiohttp import web
import psutil

from e2e_workspace import ROOT, port

OWNER = "delegation-benchmark-owner"
TOKEN = "synthetic-delegation-benchmark-token"
MOBILE_TOKEN = "synthetic-delegation-benchmark-mobile"
MODEL_TOKEN = "synthetic-delegation-benchmark-model"
DEVICE = "TE_ST_DelegationBench"
SERVER_SHA = "d5803fe194f269ae9f1c193c54c0ad5e6a410a0ea7c2d44b75ac1199987b5b11"
WORKLOADS = {
    "same_session_sequential": (True, 1),
    "fresh_sessions_sequential": (False, 1),
    "distinct_sessions_concurrent4": (False, 4),
}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def quantile(values, fraction):
    """Nearest-rank empirical quantile, never interpolated tail evidence."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def distribution(values):
    return {"n": len(values), "p50": quantile(values, .5),
            "p95": quantile(values, .95), "p99": quantile(values, .99),
            "min": min(values) if values else None, "max": max(values) if values else None}


def union_seconds(intervals):
    merged, total = None, 0.
    for start, end in sorted(intervals):
        assert end >= start
        if merged is None:
            merged = [start, end]
        elif start > merged[1]:
            total += merged[1] - merged[0]
            merged = [start, end]
        else:
            merged[1] = max(merged[1], end)
    return total + (merged[1] - merged[0] if merged else 0.)


def snapshot(pid):
    process = psutil.Process(pid)
    cpu = process.cpu_times()
    return {"at_s": time.perf_counter(), "cpu_seconds": cpu.user + cpu.system,
            "rss_bytes": process.memory_info().rss, "threads": process.num_threads()}


def process_metrics(before, after, samples, requests, wall):
    cpu = after["cpu_seconds"] - before["cpu_seconds"]
    rss = [sample["rss_bytes"] for sample in [before, *samples, after]]
    return {"cpu_seconds": cpu, "cpu_ms_per_request": cpu * 1000 / requests,
            "cpu_percent_of_one_core": cpu / wall * 100,
            "rss_start_bytes": before["rss_bytes"], "rss_end_bytes": after["rss_bytes"],
            "sampled_peak_rss_bytes": max(rss), "rss_samples": len(rss),
            "max_threads": max(s["threads"] for s in [before, *samples, after])}


def scripted_reply(payload):
    """One parent delegate round, two independent children, one parent final."""
    messages = payload["messages"]
    child = messages[0]["content"].startswith("You are an isolated delegated assistant.")
    names = {tool["function"]["name"] for tool in payload.get("tools", [])}
    last = max(i for i, value in enumerate(messages) if value["role"] == "user")
    user = messages[last]["content"]
    receipts = [value for value in messages[last + 1:] if value["role"] == "tool"]
    if child:
        key, side = re.search(r"CHILD:([a-z0-9-]+):(left|right):END", user).groups()
        serialized = json.dumps(messages)
        assert not names, ("Unexpected inherited child tools", names)
        assert not receipts and len(messages) == 2, "Child is not a fresh isolated context"
        assert "PARENT_PRIVATE_MARKER" not in serialized
        assert ("LEFT_ONLY_CONTEXT" in serialized) == (side == "left")
        assert ("RIGHT_ONLY_CONTEXT" in serialized) == (side == "right")
        message = {"role": "assistant", "content": f"CHILD_OK_{key}_{side}"}
        stage = "child_" + side
    else:
        key = re.search(r"DELEGATEBENCH:([a-z0-9-]+):END", user).group(1)
        assert "delegate_task" in names, names
        if not receipts:
            tasks = [{"goal": f"CHILD:{key}:{side}:END", "context": side.upper() + "_ONLY_CONTEXT"}
                     for side in ["left", "right"]]
            message = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "delegate-" + key, "type": "function", "function": {
                    "name": "delegate_task", "arguments": json.dumps({"tasks": tasks})}}]}
            stage = "parent_delegate"
        else:
            assert len(receipts) == 1, receipts
            result = json.loads(receipts[0]["content"])
            assert result["mode"] == "inline" and result["partial"] is False, result
            assert [item["summary"] for item in result["results"]] == [
                f"CHILD_OK_{key}_left", f"CHILD_OK_{key}_right"], result
            assert len({item["subagent_id"] for item in result["results"]}) == 2
            message = {"role": "assistant", "content": "DELEGATION_BENCH_OK_" + key}
            stage = "parent_final"
    return key, stage, message


def response_body(message, stream):
    finish = "tool_calls" if message.get("tool_calls") else "stop"
    if not stream:
        return json.dumps({"choices": [{"message": message, "finish_reason": finish}]}).encode()
    delta = dict(message)
    if "tool_calls" in delta:
        delta["tool_calls"] = [dict(value, index=i) for i, value in enumerate(delta["tool_calls"])]
    chunks = [{"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
              {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}]
    return b"".join(("data: " + json.dumps(value) + "\n\n").encode() for value in chunks) + b"data: [DONE]\n\n"


def call_metrics(calls, row):
    expected = {"parent_delegate", "child_left", "child_right", "parent_final"}
    assert len(calls) == 4 and {call["stage"] for call in calls} == expected, calls
    metrics = {}
    for kind in ["parent", "child"]:
        selected = [call for call in calls if call["stage"].startswith(kind)]
        metrics[kind + "_calls"] = len(selected)
        for field in ["request_body_bytes", "response_body_bytes", "service_ms", "actual_delay_ms"]:
            metrics[kind + "_" + field] = sum(call[field] for call in selected)
    metrics["provider_union_ms"] = 1000 * union_seconds([
        (call["received_s"], call["response_queued_s"]) for call in calls])
    children = [call for call in calls if call["stage"].startswith("child")]
    metrics["child_model_span_ms"] = 1000 * (max(c["response_queued_s"] for c in children)
                                                    - min(c["received_s"] for c in children))
    metrics["child_model_overlap_ms"] = max(0., 1000 * (
        min(c["response_queued_s"] for c in children) - max(c["received_s"] for c in children)))
    metrics["submit_to_first_provider_ms"] = 1000 * (min(c["received_s"] for c in calls) - row["submitted_s"])
    # This includes network, Server, durability, orchestration and observation overhead.
    # It is NOT an isolated runtime CPU cost or a measured serial-vs-parallel saving.
    metrics["e2e_minus_provider_union_ms"] = row["latency_ms"] - metrics["provider_union_ms"]
    return metrics


async def stop_process(process):
    if process is None or process.poll() is not None:
        return process.returncode if process else None
    process.terminate()
    try:
        return await asyncio.to_thread(process.wait, 8)
    except subprocess.TimeoutExpired:
        process.kill()
        await asyncio.to_thread(process.wait)
        raise AssertionError("Process required SIGKILL during benchmark cleanup")


async def run_workload(args, binary, server_binary, trial, workload, output):
    shared, concurrency = WORKLOADS[workload]
    calls, provider_errors, pending, observations = [], [], {}, {}
    child_active, child_peak = 0, 0
    t0 = time.perf_counter()
    clock = lambda: time.perf_counter() - t0

    async def model(request):
        nonlocal child_active, child_peak
        started = clock()
        raw = await request.read()
        is_child = False
        try:
            assert request.headers.get("Authorization") == "Bearer " + MODEL_TOKEN
            payload = json.loads(raw)
            key, stage, message = scripted_reply(payload)
            is_child = stage.startswith("child")
            if is_child:
                child_active += 1
                child_peak = max(child_peak, child_active)
            nominal = args.child_delay_ms if is_child else args.parent_delay_ms
            sleep_start = clock()
            if nominal:
                await asyncio.sleep(nominal / 1000)
            actual_delay = (clock() - sleep_start) * 1000
            body = response_body(message, bool(payload.get("stream")))
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream" if payload.get("stream") else "application/json"})
            await response.prepare(request)
            await response.write(body)
            await response.write_eof()
            ended = clock()
            calls.append({"marker": key, "stage": stage, "received_s": started,
                          "response_queued_s": ended, "service_ms": (ended - started) * 1000,
                          "nominal_delay_ms": nominal, "actual_delay_ms": actual_delay,
                          "request_body_bytes": len(raw), "response_body_bytes": len(body),
                          "request_body_sha256": hashlib.sha256(raw).hexdigest(),
                          "message_count": len(payload["messages"]), "stream": bool(payload.get("stream"))})
            return response
        except Exception as error:
            provider_errors.append(repr(error))
            raise
        finally:
            if is_child:
                child_active -= 1

    app = web.Application(client_max_size=16 * 1024 * 1024)
    app.router.add_post("/v1/chat/completions", model)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    model_port = site._server.sockets[0].getsockname()[1]
    server = agent = collector = sampler = None
    workload_tasks = []
    server_log = (output / "server.log").open("w")
    agent_log = (output / "agent.log").open("w")
    try:
        with tempfile.TemporaryDirectory(prefix="orialis-delegation-bench-state-") as directory:
            state = Path(directory)
            base = f"http://127.0.0.1:{port()}"
            env = os.environ.copy()
            for name in ["HERMES_CORE_API_KEY", "HERMES_FALLBACK_API_KEY", "OPENAI_API_KEY", "ORIALIS_NEWS_PUBLISHER_TOKEN"]:
                env.pop(name, None)
            env.update(ORIALIS_ENV="development", ORIALIS_HOST="127.0.0.1",
                       ORIALIS_PORT=base.rsplit(":", 1)[1], ORIALIS_PUBLIC_URL=base,
                       ORIALIS_DEV_DEVICE_AUTH="false", ORIALIS_AGENT_USER_ID=OWNER,
                       ORIALIS_DATABASE_URL=f"sqlite://{state}/server.sqlite?mode=rwc",
                       ORIALIS_UPLOAD_DIR=str(state / "uploads"), ORIALIS_AGENT_DEVICE_TOKEN=TOKEN)
            server = subprocess.Popen([str(server_binary)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
            async with aiohttp.ClientSession(headers={"Authorization": "Bearer " + TOKEN},
                                             timeout=aiohttp.ClientTimeout(total=args.timeout)) as client:
                async def api(method, path, body=None):
                    async with client.request(method, base + path, json=body) as response:
                        result = await response.json()
                        assert response.status < 400, (response.status, result)
                        return result
                for _ in range(500):
                    assert server.poll() is None, "Server exited during startup"
                    try:
                        await api("GET", "/api/v1/health")
                        break
                    except (aiohttp.ClientError, OSError):
                        await asyncio.sleep(.02)
                else:
                    raise TimeoutError("Server startup timed out")
                with sqlite3.connect(state / "server.sqlite") as db:
                    db.execute("INSERT INTO users(id,username,password_hash) VALUES(?,?,?)", (OWNER, OWNER, "synthetic-no-login"))
                    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('bench-mobile',?,?,'2099-01-01T00:00:00Z')",
                               (OWNER, hashlib.sha256(MOBILE_TOKEN.encode()).hexdigest()))
                command = [str(binary), "--server", base.replace("http://", "ws://") + "/api/v1/agent/ws",
                           "--device", DEVICE, "--token", TOKEN, "--db", str(state / "agent.sqlite"),
                           "--endpoint", f"http://127.0.0.1:{model_port}/v1/chat/completions",
                           "--api-key", MODEL_TOKEN, "--model", "controlled-delegation-benchmark",
                           "--verify-owner", "--expected-owner", OWNER, "--session-context",
                           "--delegation", "--stream-events"]
                (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
                agent = subprocess.Popen(command, env=env, stdout=agent_log, stderr=subprocess.STDOUT)
                for _ in range(500):
                    devices = await api("GET", "/api/v1/agent/devices")
                    if any(item["deviceId"] == DEVICE and item["online"] for item in devices["devices"]):
                        break
                    assert agent.poll() is None, "Agent exited during startup"
                    await asyncio.sleep(.02)
                else:
                    raise TimeoutError("Agent startup timed out")
                ws = await client.ws_connect(base.replace("http://", "ws://") + "/api/v1/ws",
                                             headers={"Authorization": "Session " + MOBILE_TOKEN})
                await ws.send_json({"version": 1, "type": "hello", "payload": {}})
                assert (await ws.receive_json())["type"] == "hello.ack"

                async def collect():
                    try:
                        async for raw in ws:
                            if raw.type != aiohttp.WSMsgType.TEXT:
                                continue
                            envelope = json.loads(raw.data)
                            now = clock()
                            if envelope.get("type") == "ping":
                                await ws.send_json({"version": 1, "type": "pong", "payload": {}})
                            payload = envelope.get("payload", {})
                            if envelope.get("type") == "message" and payload.get("role") == "assistant":
                                content = payload.get("content", "")
                                if content.startswith("DELEGATION_BENCH_OK_"):
                                    key = content[len("DELEGATION_BENCH_OK_"):]
                                    assert key in pending, ("Unexpected/duplicate final", key)
                                    future = pending.pop(key)
                                    assert payload["replyToMessageId"] == "input-" + key, payload
                                    observations[key] = {"mobile_final_s": now, "message": payload}
                                    future.set_result(now)
                    finally:
                        for future in pending.values():
                            if not future.done():
                                future.set_exception(RuntimeError("Mobile collector closed before final"))
                collector = asyncio.create_task(collect())

                async def create(label):
                    conversation = "bench-" + label
                    await api("POST", "/api/v1/conversations", {"id": conversation, "title": "Synthetic delegation benchmark"})
                    await api("PUT", f"/api/v1/conversations/{conversation}/agent-device", {"deviceId": DEVICE})
                    return conversation

                async def turn(conversation, key, batch_start):
                    pending[key] = asyncio.get_running_loop().create_future()
                    future = pending[key]
                    submitted = clock()
                    try:
                        await api("POST", f"/api/v1/conversations/{conversation}/messages", {
                            "id": "input-" + key, "content": "DELEGATEBENCH:" + key + ":END PARENT_PRIVATE_MARKER"})
                        post_ack = clock()
                        final = await asyncio.wait_for(future, args.timeout)
                        return {"marker": key, "conversation": conversation, "submitted_s": submitted,
                                "post_ack_s": post_ack, "mobile_final_s": final,
                                "client_admission_wait_ms": (submitted - batch_start) * 1000,
                                "latency_ms": (final - submitted) * 1000,
                                "post_ack_ms": (post_ack - submitted) * 1000}
                    finally:
                        pending.pop(key, None)

                async def settle():
                    # Outside measured request latency/throughput. Require the Agent's
                    # input and event journals to settle before resetting observations.
                    for _ in range(500):
                        with sqlite3.connect(state / "agent.sqlite") as db:
                            count = db.execute("SELECT count(*) FROM jobs WHERE state='ready'").fetchone()[0]
                            for table in ["gateway_event_outbox", "gateway_event_completions"]:
                                if db.execute("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)", (table,)).fetchone()[0]:
                                    count += db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                        if count == 0 and child_active == 0:
                            await asyncio.sleep(.05)
                            return
                        await asyncio.sleep(.02)
                    raise TimeoutError("Agent journals did not settle")

                await turn(await create("warm"), "warm", clock())
                await settle()
                assert len(calls) == 4 and not provider_errors, (calls, provider_errors)
                shared_conversation = await create("shared") if shared else None
                conversations = [shared_conversation] * args.iterations if shared else [await create(str(i)) for i in range(args.iterations)]
                calls.clear()
                child_peak = 0
                samples = {"agent": [], "server": [], "harness": []}
                pids = {"agent": agent.pid, "server": server.pid, "harness": os.getpid()}
                before = {name: snapshot(pid) for name, pid in pids.items()}
                sample_stop = asyncio.Event()
                async def sample():
                    while not sample_stop.is_set():
                        for name, pid in pids.items():
                            samples[name].append(snapshot(pid))
                        try:
                            await asyncio.wait_for(sample_stop.wait(), args.sample_ms / 1000)
                        except asyncio.TimeoutError:
                            pass
                sampler = asyncio.create_task(sample())
                semaphore = asyncio.Semaphore(concurrency)
                batch_start = clock()
                async def one(index):
                    async with semaphore:
                        return await turn(conversations[index], f"r{trial}-{index}", batch_start)
                workload_tasks = [asyncio.create_task(one(index)) for index in range(args.iterations)]
                rows = await asyncio.gather(*workload_tasks)
                workload_tasks.clear()
                batch_end = clock()
                wall = batch_end - batch_start
                after = {name: snapshot(pid) for name, pid in pids.items()}
                sample_stop.set()
                await sampler
                sampler = None
                drain_start = clock()
                await settle()
                drain_ms = (clock() - drain_start) * 1000
                settled = {name: snapshot(pid) for name, pid in pids.items()}
                if collector.done():
                    collector.result()
                    raise AssertionError("Mobile collector ended before workload verification")
                assert not provider_errors, provider_errors
                assert len(calls) == args.iterations * 4, len(calls)
                for row in rows:
                    current = [call for call in calls if call["marker"] == row["marker"]]
                    row.update(call_metrics(current, row))
                # Verify every mobile final was durable. Reads are outside timing.
                with sqlite3.connect(state / "server.sqlite") as db:
                    for row in rows:
                        stored = db.execute("SELECT content,reply_to_message_id FROM messages WHERE id=?", (observations[row["marker"]]["message"]["id"],)).fetchone()
                        assert stored == ("DELEGATION_BENCH_OK_" + row["marker"], "input-" + row["marker"]), stored
                with sqlite3.connect(state / "agent.delegation.sqlite") as db:
                    counts = dict(db.execute("SELECT status,count(*) FROM delegation_children GROUP BY status"))
                    assert counts == {"completed": (args.iterations + 1) * 2}, counts
                result = {"trial": trial, "workload": workload, "requests": args.iterations,
                          "failures": 0, "client_concurrency": concurrency,
                          "session_policy": "one growing-history session" if shared else "fresh session per user request",
                          "children_per_request": 2, "inherited_child_tools": [],
                          "child_runtime_configuration": "CLI default; no serial child baseline/configuration override",
                          "peak_observed_child_model_requests": child_peak, "wall_seconds": wall,
                          "requests_per_second": args.iterations / wall,
                          "latency_ms": distribution([row["latency_ms"] for row in rows]),
                          "post_measurement_drain_ms": drain_ms,
                          "processes": {name: process_metrics(before[name], after[name], samples[name], args.iterations, wall) for name in pids},
                          "processes_including_post_final_drain": {name: process_metrics(before[name], settled[name], samples[name] + [after[name]], args.iterations, wall + drain_ms / 1000) for name in pids},
                          "per_request_metrics": {field: distribution([row[field] for row in rows]) for field in rows[0] if field.endswith("_ms") or field.endswith("_bytes") or field.endswith("_calls")},
                          "provider_calls": len(calls), "child_provider_calls": sum(c["stage"].startswith("child") for c in calls),
                          "request_body_bytes": sum(c["request_body_bytes"] for c in calls),
                          "response_body_bytes": sum(c["response_body_bytes"] for c in calls),
                          "rows": rows, "model_calls": calls, "process_samples": samples}
                collector.cancel()
                await asyncio.gather(collector, return_exceptions=True)
                collector = None
                await ws.close()
            assert await stop_process(agent) == 0, "Agent shutdown was not clean"
            agent = None
            await stop_process(server)
            server = None
            return result
    finally:
        for task in workload_tasks:
            task.cancel()
        if workload_tasks:
            await asyncio.gather(*workload_tasks, return_exceptions=True)
        for task in [collector, sampler]:
            if task:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
        for process in [agent, server]:
            await stop_process(process)
        await runner.cleanup()
        server_log.close()
        agent_log.close()
        (output / "model-calls.json").write_text(json.dumps(calls, indent=2) + "\n")
        if provider_errors:
            (output / "provider-errors.json").write_text(json.dumps(provider_errors, indent=2) + "\n")


async def main(args):
    args.out.mkdir(parents=True, exist_ok=False)
    binary_hash, server_hash = sha(args.binary), sha(args.server)
    assert not args.expected_binary_sha256 or binary_hash == args.expected_binary_sha256, "Agent SHA mismatch"
    assert server_hash == args.expected_server_sha256, "Frozen Server SHA mismatch"
    manifest = {"binary": str(args.binary.resolve()), "binary_sha256": binary_hash,
                "server": str(args.server.resolve()), "server_sha256": server_hash,
                "harness_sha256": sha(Path(__file__)), "iterations_per_workload": args.iterations,
                "trials": args.trials, "workloads": args.workloads,
                "nominal_child_delay_ms": args.child_delay_ms, "nominal_parent_delay_ms": args.parent_delay_ms,
                "rss_sample_ms": args.sample_ms, "cpu_count": os.cpu_count(),
                "cpu_time_resolution_ms": 1000 / os.sysconf("SC_CLK_TCK"),
                "quantiles": "nearest rank; 30-request trial p99 is its maximum, not a stable production-tail estimate",
                "observation": "HTTP user submission start to actual authenticated mobile WebSocket persisted final; no polling in timed region",
                "scope": "Actual fixed Server and main Rust Agent; controlled local HTTP provider; two isolated no-tool children; default child runtime limits only",
                "limits": ["No serial child comparison or Python/prototype functional-equivalence baseline",
                           "Same-session requests are sequential; overlapping same-session inputs have cancellation semantics and are not equivalent work",
                           "Fresh-session concurrency varies user load, not child runtime concurrency configuration",
                           "Model service union subtraction includes network, Server, durability and observation overhead; it is not isolated CPU cost",
                           "HTTP body byte counts exclude headers/TLS/framing outside SSE body; localhost only",
                           "CPU is process user+system delta; RSS is sampled, not an exact high-water mark; harness CPU/RSS reported separately",
                           "Startup, one warmup, conversation creation, drain and durability verification excluded from timed workload",
                           "No live-provider quality, external-effect cost or production deployment claim"]}
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []
    try:
        with tempfile.TemporaryDirectory(prefix="orialis-delegation-bench-binaries-") as directory:
            binary, server = Path(directory) / "agent", Path(directory) / "server"
            shutil.copy2(args.binary, binary)
            shutil.copy2(args.server, server)
            assert sha(binary) == binary_hash and sha(server) == server_hash
            for trial in range(1, args.trials + 1):
                order = args.workloads if trial % 2 else list(reversed(args.workloads))
                for workload in order:
                    output = args.out / f"trial-{trial}-{workload}"
                    output.mkdir()
                    result = await run_workload(args, binary, server, trial, workload, output)
                    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
                    results.append(result)
                    print(json.dumps({key: value for key, value in result.items() if key not in {"rows", "model_calls", "process_samples", "per_request_metrics"}}), flush=True)
            assert sha(binary) == binary_hash and sha(server) == server_hash
        aggregate = {}
        for workload in args.workloads:
            runs = [result for result in results if result["workload"] == workload]
            aggregate[workload] = {"requests": sum(run["requests"] for run in runs),
                                   "pooled_latency_ms": distribution([row["latency_ms"] for run in runs for row in run["rows"]]),
                                   "trial_p50_ms": [run["latency_ms"]["p50"] for run in runs],
                                   "trial_p95_ms": [run["latency_ms"]["p95"] for run in runs],
                                   "trial_p99_ms": [run["latency_ms"]["p99"] for run in runs],
                                   "trial_requests_per_second": [run["requests_per_second"] for run in runs],
                                   "trial_process_metrics": [run["processes"] for run in runs],
                                   "trial_parent_calls_per_request": [run["per_request_metrics"]["parent_calls"] for run in runs],
                                   "trial_child_calls_per_request": [run["per_request_metrics"]["child_calls"] for run in runs],
                                   "trial_body_bytes_per_request": [(run["request_body_bytes"] + run["response_body_bytes"]) / run["requests"] for run in runs],
                                   "trial_actual_child_service_ms": [run["per_request_metrics"]["child_service_ms"] for run in runs]}
        final = {"manifest": manifest, "passed_workload_runs": len(results), "aggregate": aggregate}
        (args.out / "summary.json").write_text(json.dumps(final, indent=2) + "\n")
        print(json.dumps(final, indent=2), flush=True)
    except BaseException as error:
        (args.out / "failure.json").write_text(json.dumps({"error": repr(error), "completed_workload_runs": len(results)}, indent=2) + "\n")
        raise


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Frozen main Agent executable; no build performed")
    parser.add_argument("--expected-binary-sha256")
    parser.add_argument("--server", type=Path, default=ROOT / "hermes-rust-core/results/control-responsive-next/server-control-responsive")
    parser.add_argument("--expected-server-sha256", default=SERVER_SHA)
    parser.add_argument("--out", type=Path, required=True, help="New output directory; existing paths refused")
    parser.add_argument("--iterations", type=int, choices=range(25, 41), default=30)
    parser.add_argument("--trials", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--workloads", nargs="+", choices=list(WORKLOADS), default=list(WORKLOADS))
    parser.add_argument("--child-delay-ms", type=float, default=20.)
    parser.add_argument("--parent-delay-ms", type=float, default=0.)
    parser.add_argument("--sample-ms", type=float, default=20.)
    parser.add_argument("--timeout", type=float, default=30.)
    args = parser.parse_args()
    if not 0 <= args.child_delay_ms <= 1000 or not 0 <= args.parent_delay_ms <= 1000:
        parser.error("model delays must be 0..1000 ms")
    if not 5 <= args.sample_ms <= 1000 or not 1 <= args.timeout <= 300:
        parser.error("sample interval must be 5..1000 ms; timeout 1..300 s")
    if len(set(args.workloads)) != len(args.workloads):
        parser.error("workloads must not repeat")
    return args


if __name__ == "__main__":
    asyncio.run(main(parse_args()))
