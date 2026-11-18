#!/usr/bin/env python3
"""Owner-bound durable-context on/off overhead: same binary, controlled text workload.
Not a Python comparison or live model benchmark. All local children belong to
this invocation. Run without concurrent builds; three alternating fresh trials.
"""
import argparse
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import socket
import sqlite3
import statistics
import subprocess
import tempfile
import time
import uuid

import aiohttp
from aiohttp import web
import psutil

ROOT=Path(__file__).resolve().parents[2]


def free_port():
    with socket.socket() as socket_:
        socket_.bind(("127.0.0.1",0));return socket_.getsockname()[1]


def snapshot(pid):
    try:
        root=psutil.Process(pid);processes=[root]+root.children(recursive=True)
    except psutil.NoSuchProcess:
        return {"rss_bytes":0,"cpu_seconds":0.,"processes":0,"threads":0}
    rss=threads=0;cpu=0.
    for process in processes:
        try:
            rss+=process.memory_info().rss;times=process.cpu_times();cpu+=times.user+times.system;threads+=process.num_threads()
        except psutil.NoSuchProcess:pass
    return {"rss_bytes":rss,"cpu_seconds":cpu,"processes":len(processes),"threads":threads}


def quantile(values,q):
    values=sorted(values);return values[min(len(values)-1,max(0,math.ceil(len(values)*q)-1))] if values else None


async def main(args):
    args.out.mkdir(parents=True,exist_ok=True)
    provider_records=[]
    async def model(request):
        data=await request.json();started=time.perf_counter()
        prompt=next(m["content"] for m in reversed(data["messages"]) if m["role"]=="user")
        answer=f"ANSWER:{prompt}| identical controlled response."
        canonical=dict(data);canonical.pop("stream",None)
        signature=hashlib.sha256(json.dumps(canonical,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        if data.get("stream"):
            response=web.StreamResponse(headers={"Content-Type":"text/event-stream"});await response.prepare(request)
            count=8
            for index in range(count):
                await asyncio.sleep(args.model_delay_ms/1000/count)
                text=answer[index*len(answer)//count:(index+1)*len(answer)//count]
                value={"choices":[{"index":0,"delta":{"content":text},"finish_reason":None}]}
                await response.write(("data: "+json.dumps(value,ensure_ascii=False)+"\n\n").encode())
            await response.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');await response.write_eof()
        else:
            # Same eight delay intervals, not a single shorter scheduling wait.
            for _ in range(8):await asyncio.sleep(args.model_delay_ms/1000/8)
            response=web.json_response({"choices":[{"message":{"role":"assistant","content":answer}}]})
        provider_records.append({"prompt":prompt,"stream":bool(data.get("stream")),"request_without_stream_sha256":signature,"request_bytes":len(json.dumps(data,ensure_ascii=False).encode()),"provider_elapsed_ms":(time.perf_counter()-started)*1000})
        return response
    model_app=web.Application();model_app.router.add_post("/v1/chat/completions",model)
    runner=web.AppRunner(model_app);await runner.setup();site=web.TCPSite(runner,"127.0.0.1",0);await site.start();model_port=site._server.sockets[0].getsockname()[1]
    all_rows=[]
    try:
        for trial in range(args.trials):
            for streaming in ([False,True] if trial%2==0 else [True,False]):
                mode="durable_on" if streaming else "durable_off"
                output=args.out/f"trial-{trial+1}-{mode}";output.mkdir(exist_ok=True)
                with tempfile.TemporaryDirectory(prefix="orialis-stream-bench-") as temp:
                    state=Path(temp);base=f"http://127.0.0.1:{free_port()}";token="synthetic-stream-benchmark-token"
                    env=os.environ.copy();env.update(ORIALIS_ENV="development",ORIALIS_HOST="127.0.0.1",ORIALIS_PORT=base.rsplit(":",1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH="false",ORIALIS_AGENT_USER_ID="benchmark-owner",ORIALIS_DATABASE_URL=f"sqlite://{state}/server.sqlite?mode=rwc",ORIALIS_UPLOAD_DIR=str(state/"uploads"),ORIALIS_AGENT_DEVICE_TOKEN=token)
                    server_log=(output/"server.log").open("w");agent_log=(output/"agent.log").open("w")
                    server=subprocess.Popen([str(args.server_binary)],env=env,stdout=server_log,stderr=subprocess.STDOUT);agent=None
                    try:
                        async with aiohttp.ClientSession(headers={"Authorization":"Bearer "+token},timeout=aiohttp.ClientTimeout(total=10)) as client:
                            async def api(method,path,body=None):
                                async with client.request(method,base+path,json=body) as response:
                                    result=await response.json();assert response.status<400,(response.status,result);return result
                            for _ in range(300):
                                if server.poll() is not None:raise AssertionError("server exited")
                                try:await api("GET","/api/v1/health");break
                                except (aiohttp.ClientError,OSError):await asyncio.sleep(.02)
                            with sqlite3.connect(state/"server.sqlite") as db:db.execute("INSERT INTO users(id,username,password_hash) VALUES('benchmark-owner','benchmark-owner','synthetic-no-login')")
                            await api("GET","/api/v1/conversations")
                            command=[str(args.binary),"--server",base.replace("http://","ws://")+"/api/v1/agent/ws","--device","TE_ST_Rust","--token",token,"--db",str(state/"agent.sqlite"),"--endpoint",f"http://127.0.0.1:{model_port}/v1/chat/completions","--model","identical-controlled-model"]
                            command.extend(["--verify-owner","--expected-owner","benchmark-owner"])
                            if streaming:command.append("--session-context")
                            startup=time.perf_counter();agent=subprocess.Popen(command,stdout=agent_log,stderr=subprocess.STDOUT)
                            for _ in range(1000):
                                devices=await api("GET","/api/v1/agent/devices")
                                if any(d["deviceId"]=="TE_ST_Rust" and d["online"] for d in devices["devices"]):break
                                if agent.poll() is not None:raise AssertionError("agent exited")
                                await asyncio.sleep(.01)
                            startup_ms=(time.perf_counter()-startup)*1000
                            async def conversation():
                                id_="bench-"+uuid.uuid4().hex
                                await api("POST","/api/v1/conversations",{"id":id_,"title":"Synthetic benchmark"})
                                await api("PUT",f"/api/v1/conversations/{id_}/agent-device",{"deviceId":"TE_ST_Rust"})
                                return id_
                            async def turn(conversation_id,prompt):
                                started=time.perf_counter()
                                await api("POST",f"/api/v1/conversations/{conversation_id}/messages",{"id":"input-"+uuid.uuid4().hex,"content":prompt})
                                deadline=time.monotonic()+30
                                while time.monotonic()<deadline:
                                    page=await api("GET",f"/api/v1/conversations/{conversation_id}/messages?limit=500")
                                    if any(m["role"]=="assistant" and m["content"]==f"ANSWER:{prompt}| identical controlled response." for m in page["items"]):
                                        return (time.perf_counter()-started)*1000
                                    await asyncio.sleep(.002)
                                raise TimeoutError("persisted final not found")
                            await turn(await conversation(),"warmup")
                            await asyncio.sleep(.1)
                            for concurrency in [1,4]:
                                conversations=[await conversation() for _ in range(args.iterations)]
                                label="sequential" if concurrency==1 else "concurrent4"
                                before=snapshot(agent.pid);server_before=snapshot(server.pid);samples=[];server_samples=[];stop_sample=asyncio.Event()
                                async def sample():
                                    while not stop_sample.is_set():
                                        samples.append(snapshot(agent.pid));server_samples.append(snapshot(server.pid))
                                        await asyncio.sleep(.02)
                                sampler=asyncio.create_task(sample());sem=asyncio.Semaphore(concurrency)
                                provider_start=len(provider_records)
                                async def run(index):
                                    async with sem:
                                        try:return {"index":index,"ok":True,"latency_ms":await turn(conversations[index],f"{label}-{index:03}")}
                                        except Exception as error:return {"index":index,"ok":False,"error":str(error)}
                                started=time.perf_counter();rows=await asyncio.gather(*(run(i) for i in range(args.iterations)));wall=time.perf_counter()-started
                                # Include the asynchronous event/ACK drain in CPU
                                # accounting, but not final-persistence latency.
                                drain_started=time.perf_counter()
                                for _ in range(200):
                                    with sqlite3.connect(state/"agent.sqlite") as db:
                                        pending=db.execute("SELECT COUNT(*) FROM jobs WHERE state='ready'").fetchone()[0]
                                    if pending==0:break
                                    await asyncio.sleep(.01)
                                drain_ms=(time.perf_counter()-drain_started)*1000
                                after=snapshot(agent.pid);server_after=snapshot(server.pid);stop_sample.set();await sampler
                                latencies=[r["latency_ms"] for r in rows if r["ok"]];records=provider_records[provider_start:]
                                metrics={"mode":mode,"trial":trial+1,"workload":label,"requests":args.iterations,"successes":len(latencies),"failures":args.iterations-len(latencies),"startup_online_ms":startup_ms,"wall_seconds":wall,"throughput_requests_per_second":len(latencies)/wall,"p50_ms":quantile(latencies,.5),"p95_ms":quantile(latencies,.95),"p99_ms":quantile(latencies,.99),"agent_cpu_seconds":after["cpu_seconds"]-before["cpu_seconds"],"agent_cpu_ms_per_request":1000*(after["cpu_seconds"]-before["cpu_seconds"])/args.iterations,"agent_peak_rss_bytes":max([after["rss_bytes"]]+[r["rss_bytes"] for r in samples]),"agent_idle_rss_bytes":before["rss_bytes"],"agent_hot_rss_bytes":after["rss_bytes"],"server_cpu_seconds":server_after["cpu_seconds"]-server_before["cpu_seconds"],"server_peak_rss_bytes":max([server_after["rss_bytes"]]+[r["rss_bytes"] for r in server_samples]),"event_and_reply_drain_ms":drain_ms,"provider_requests":len(records),"provider_p50_elapsed_ms":quantile([r["provider_elapsed_ms"] for r in records],.5),"rows":rows,"provider_records":records}
                                assert len(records)==args.iterations and all(not r["stream"] for r in records),"unexpected provider retries or stream mode"
                                all_rows.append(metrics);(output/f"{label}.json").write_text(json.dumps(metrics,indent=2)+"\n");print(json.dumps({k:v for k,v in metrics.items() if k not in {"rows","provider_records"}}),flush=True)
                    finally:
                        for process in [agent,server]:
                            if process is not None and process.poll() is None:
                                process.terminate()
                                try:await asyncio.to_thread(process.wait,5)
                                except subprocess.TimeoutExpired:process.kill();await asyncio.to_thread(process.wait)
                        server_log.close();agent_log.close()
    finally:
        await runner.cleanup()
    # Canonical prompts/tools/settings must be byte-identical except stream flag.
    signatures={}
    for row in all_rows:
        for record in row["provider_records"]:signatures.setdefault(record["prompt"],set()).add(record["request_without_stream_sha256"])
    # Durable context adds its real session_search tool schema; compare deterministic
    # prompts/output and record wire bytes rather than falsely claiming identical schemas.
    summary=[]
    for mode in ["durable_off","durable_on"]:
        for workload in ["sequential","concurrent4"]:
            group=[r for r in all_rows if r["mode"]==mode and r["workload"]==workload];latencies=[v["latency_ms"] for row in group for v in row["rows"] if v["ok"]];count=sum(r["requests"] for r in group)
            summary.append({"mode":mode,"workload":workload,"requests":count,"failures":sum(r["failures"] for r in group),"p50_ms":quantile(latencies,.5),"p95_ms":quantile(latencies,.95),"p99_ms":quantile(latencies,.99),"throughput_requests_per_second":len(latencies)/sum(r["wall_seconds"] for r in group),"agent_cpu_ms_per_request":1000*sum(r["agent_cpu_seconds"] for r in group)/count,"agent_peak_rss_bytes":max(r["agent_peak_rss_bytes"] for r in group),"agent_hot_rss_median_bytes":statistics.median(r["agent_hot_rss_bytes"] for r in group),"provider_p50_elapsed_ms":statistics.median(r["provider_p50_elapsed_ms"] for r in group)})
    report={"scope":"Within-Rust owner-verified durable context off/on overhead. Same controlled textual question/answer and final-only provider; enabled profile adds durable turn/tool receipts and session_search schema. No Python or live-model equivalence claim","agent_binary_sha256":hashlib.sha256(args.binary.read_bytes()).hexdigest(),"server_binary_sha256":hashlib.sha256(args.server_binary.read_bytes()).hexdigest(),"model_nominal_total_delay_ms":args.model_delay_ms,"model_chunks":8,"iterations_per_workload_per_trial":args.iterations,"trials":args.trials,"final_poll_interval_ms":2,"process_sampling_interval_ms":20,"canonical_provider_requests_equal":False,"schema_difference":"durable_on adds real session_search tool; prompt/content and controlled answer are equal","summary":summary,"limitations":["Shared unpinned executor, no CPU quota isolation or confidence intervals.","CPU timer granularity is typically 10 ms; includes final event/ACK drain.","HTTP final-persistence polling adds up to one nominal polling interval.","Fresh DB per mode/trial; sequential and 4-way groups use independent conversations.","Same eight nominal provider sleeps; actual scheduler delay is recorded separately.","No mobile subscriber, live model, TLS or production deployment measurement."]}
    (args.out/"summary.json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))


if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,default=ROOT/"hermes-rust-core/target/release/orialis_agent");p.add_argument("--server-binary",type=Path,default=ROOT/"orialis/target/release/orialis-server");p.add_argument("--out",type=Path,default=ROOT/"hermes-rust-core/results/context-overhead");p.add_argument("--iterations",type=int,default=40);p.add_argument("--trials",type=int,default=3);p.add_argument("--model-delay-ms",type=float,default=20);a=p.parse_args();assert a.iterations>=40 and a.trials>=1 and a.model_delay_ms>=0;asyncio.run(main(a))
