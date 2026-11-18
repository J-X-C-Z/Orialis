#!/usr/bin/env python3
"""Frozen Agent transport-stage experiment; no Agent implementation changes.

Keeps prior benchmarks intact. Model response write/NODELAY controls are local
harness controls. Optional server shim touches only accepted agent WS sockets.
Proxy timestamps are receive observations, never claimed to be internal send
instrumentation. Direct cases preserve the original connection topology.
"""
import argparse
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid

import aiohttp
from aiohttp import web
import websockets

ROOT=Path(__file__).resolve().parents[2]


def free_port():
    with socket.socket() as s:s.bind(("127.0.0.1",0));return s.getsockname()[1]


def percentile(values,p):
    values=sorted(values);return values[min(len(values)-1,max(0,math.ceil(len(values)*p)-1))] if values else None


def now():return time.perf_counter()


def answer_for(data):
    last=next((m.get("content","") for m in reversed(data["messages"]) if m.get("role")=="user"),"")
    text=last if isinstance(last,str) else json.dumps(last)
    match=re.search(r"BENCH_ID=([A-Za-z0-9_.-]+)",text)
    marker=match.group(1) if match else "unknown"
    return marker,"ANSWER:"+marker+": controlled complete answer."


class ObservedResponse(web.Response):
    def __init__(self,record,**kwargs):super().__init__(**kwargs);self.record=record
    async def write_eof(self,data=b""):
        self.record["response_write_eof_start"]=now()
        await super().write_eof(data)
        self.record["response_queued"]=now()


async def run_case(args,case,shim):
    output=args.out/case["name"];output.mkdir(parents=True,exist_ok=True)
    model_records=[];wire=[];proxy_errors=[];socket_connections=[]
    def record(data,transport,started):
        marker,answer=answer_for(data);sock=transport.get_extra_info("socket")
        row={"marker":marker,"request_start":started,"request_parsed":now(),"stream":bool(data.get("stream")),"primary":bool(data.get("tools")),"socket_nodelay":sock.getsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY),"socket_fd":sock.fileno()}
        model_records.append(row);return row,answer
    async def complete(request):
        started=now();data=await request.json();row,answer=record(data,request.transport,started)
        await asyncio.sleep(args.model_delay_ms/1000)
        if data.get("stream"):
            response=web.StreamResponse(headers={"Content-Type":"text/event-stream"});await response.prepare(request);row["headers_queued"]=now()
            meta={"id":"synthetic-probe","model":data.get("model","bench-chat"),"object":"chat.completion.chunk","created":0}
            for delta,reason in [({"role":"assistant"},None),({"content":answer[:len(answer)//2]},None),({"content":answer[len(answer)//2:]},None),({},"stop")]:
                await response.write(("data: "+json.dumps({**meta,"choices":[{"index":0,"delta":delta,"finish_reason":reason}]})+"\n\n").encode())
            await response.write(b"data: [DONE]\n\n");await response.write_eof();row["response_queued"]=now();return response
        body=json.dumps({"id":"synthetic-probe","object":"chat.completion","model":data.get("model","bench-chat"),"choices":[{"index":0,"message":{"role":"assistant","content":answer},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20}}).encode()
        return ObservedResponse(row,body=body,content_type="application/json")
    async def prepare(request,response):
        if isinstance(response,ObservedResponse):response.record["headers_prepare"]=now()
    model_mode=case["model"]
    runner=None;raw_server=None
    if model_mode=="aiohttp_default":
        app=web.Application();app.router.add_post("/v1/chat/completions",complete);app.router.add_get("/health",lambda _:web.json_response({"ok":True}));app.on_response_prepare.append(prepare)
        runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,"127.0.0.1",0);await site.start();model_port=site._server.sockets[0].getsockname()[1]
    else:
        async def raw_model(reader,writer):
            sock=writer.get_extra_info("socket");sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,case["model_nodelay"])
            socket_connections.append({"fd":sock.fileno(),"nodelay":sock.getsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY)})
            try:
                while True:
                    header=await reader.readuntil(b"\r\n\r\n");started=now();match=re.search(rb"(?im)^content-length:\s*(\d+)",header)
                    body=await reader.readexactly(int(match.group(1)) if match else 0);data=json.loads(body);row,answer=record(data,writer.transport,started)
                    await asyncio.sleep(args.model_delay_ms/1000)
                    payload=json.dumps({"choices":[{"message":{"role":"assistant","content":answer},"finish_reason":"stop"}]}).encode()
                    headers=f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: keep-alive\r\n\r\n".encode()
                    if case["model"]=="raw_split":
                        writer.write(headers);await writer.drain();row["headers_queued"]=now();await asyncio.sleep(.001);writer.write(payload)
                    else:
                        writer.write(headers+payload);row["headers_queued"]=now()
                    await writer.drain();row["response_queued"]=now()
            except (asyncio.IncompleteReadError,ConnectionError):pass
            finally:writer.close();await writer.wait_closed()
        raw_server=await asyncio.start_server(raw_model,"127.0.0.1",0);model_port=raw_server.sockets[0].getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="orialis-latency-probe-") as temp:
        state=Path(temp);base=f"http://127.0.0.1:{free_port()}";token="synthetic-latency-probe-token"
        env=os.environ.copy();env.update(ORIALIS_ENV="development",ORIALIS_HOST="127.0.0.1",ORIALIS_PORT=base.rsplit(":",1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH="1",ORIALIS_DATABASE_URL=f"sqlite://{state}/server.sqlite?mode=rwc",ORIALIS_UPLOAD_DIR=str(state/"uploads"),ORIALIS_AGENT_DEVICE_TOKEN=token)
        if case.get("server_ws_nodelay") is not None:
            env.update(LD_PRELOAD=str(shim),ORIALIS_TEST_WS_NODELAY=str(case["server_ws_nodelay"]))
        log=(output/"server.log").open("w+");agent_log=(output/"agent.log").open("w+")
        server=subprocess.Popen([str(args.server_binary)],env=env,stdout=log,stderr=subprocess.STDOUT);agent=None;proxy_server=None
        try:
            async with aiohttp.ClientSession(headers={"x-orialis-device-id":"latency-probe-client"},timeout=aiohttp.ClientTimeout(total=10)) as client:
                async def api(method,path,body=None):
                    async with client.request(method,base+path,json=body) as response:
                        payload=await response.json();assert response.status<400,(response.status,payload);return payload
                for _ in range(500):
                    if server.poll() is not None:log.seek(0);raise RuntimeError(log.read())
                    try:await api("GET","/api/v1/health");break
                    except (aiohttp.ClientError,OSError):await asyncio.sleep(.02)
                await api("GET","/api/v1/conversations")
                upstream_url=base.replace("http://","ws://")+"/api/v1/agent/ws";agent_url=upstream_url
                if case.get("proxy"):
                    async def proxy(socket_):
                        try:
                            async with websockets.connect(upstream_url,additional_headers={"Authorization":f"Bearer {token}"}) as upstream:
                                async def forward(source,destination,direction):
                                    async for raw in source:
                                        frame=json.loads(raw);wire.append({"time":now(),"direction":direction,"frame":frame});await destination.send(raw)
                                tasks=[asyncio.create_task(forward(socket_,upstream,"agent_to_server")),asyncio.create_task(forward(upstream,socket_,"server_to_agent"))]
                                done,pending=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
                                for task in pending:task.cancel()
                                await asyncio.gather(*tasks,return_exceptions=True)
                                for task in done:
                                    try:task.result()
                                    except websockets.ConnectionClosed:pass
                        except websockets.ConnectionClosed:pass
                        except Exception as error:proxy_errors.append(str(error))
                    proxy_server=await websockets.serve(proxy,"127.0.0.1",0);agent_url=f"ws://127.0.0.1:{proxy_server.sockets[0].getsockname()[1]}/api/v1/agent/ws"
                if case.get("variant","rust")=="python":
                    command=[str(args.python),str(ROOT/"orialis-full-eval/python_baseline/launch.py"),"--component-integration","--hermes",str(ROOT/"upstream-hermes"),"--orialis",str(ROOT/"orialis"),"--home",str(state/"python-home"),"--server",agent_url,"--device","TE_ST_Rust","--token",token,"--model-base",f"http://127.0.0.1:{model_port}/v1","--model","bench-chat","--vision-model","bench-vision"]
                else:
                    command=[str(args.binary),"--server",agent_url,"--device","TE_ST_Rust","--token",token,"--db",str(state/"agent.sqlite"),"--endpoint",f"http://127.0.0.1:{model_port}/v1/chat/completions","--model","bench-chat"]
                    if case.get("streaming"):command.append("--stream-events")
                agent=subprocess.Popen(command,stdout=agent_log,stderr=subprocess.STDOUT)
                ready=False
                for _ in range(3000):
                    if agent.poll() is not None:agent_log.seek(0);raise RuntimeError(agent_log.read())
                    devices=await api("GET","/api/v1/agent/devices")
                    if any(d["deviceId"]=="TE_ST_Rust" and d["online"] for d in devices["devices"]):ready=True;break
                    await asyncio.sleep(.02)
                assert ready,"agent startup timed out"
                connection=sqlite3.connect(f"file:{state}/server.sqlite?mode=ro",uri=True)
                rows=[]
                for index in range(-2,case.get("n",args.iterations)):
                    marker=f"probe-{index+2:03}";prompt="BENCH_ID="+marker;expected="ANSWER:"+marker+": controlled complete answer."
                    conversation="probe-"+uuid.uuid4().hex;input_id="input-"+uuid.uuid4().hex
                    await api("POST","/api/v1/conversations",{"id":conversation,"title":"Synthetic stage probe"});await api("PUT",f"/api/v1/conversations/{conversation}/agent-device",{"deviceId":"TE_ST_Rust"})
                    row={"index":index,"marker":marker,"input_id":input_id,"submitted":now()};db_result={}
                    async def observe_db():
                        previous=now()
                        for _ in range(15000):
                            stamp=now();found=connection.execute("SELECT id FROM messages WHERE conversation_id=? AND role='assistant' AND content=? AND id LIKE 'final_%'",(conversation,expected)).fetchone()
                            if found:db_result.update(id=found[0],commit_visible=now(),last_absent=previous);return
                            previous=stamp;await asyncio.sleep(.001)
                        raise TimeoutError("database final missing")
                    observer=asyncio.create_task(observe_db())
                    try:
                        await api("POST",f"/api/v1/conversations/{conversation}/messages",{"id":input_id,"content":prompt});row["submit_http_returned"]=now()
                        for _ in range(15000):
                            page=await api("GET",f"/api/v1/conversations/{conversation}/messages?limit=500")
                            found=next((m for m in page["items"] if m["id"].startswith("final_") and m["content"]==expected),None)
                            if found:row["client_observed"]=now();row["final_id"]=found["id"];break
                            await asyncio.sleep(.002)
                        else:raise TimeoutError("HTTP final missing")
                        await observer
                    except Exception:
                        observer.cancel();await asyncio.gather(observer,return_exceptions=True);raise
                    row["db"]=db_result
                    # Allow timestamp bookkeeping of the response body to finish.
                    await asyncio.sleep(0)
                    calls=[r for r in model_records if r["marker"]==marker]
                    primary=[r for r in calls if r["primary"]] or calls
                    assert primary and all("response_queued" in r for r in primary),(marker,calls)
                    row["model_calls"]=calls
                    row["model_request_start"]=min(r["request_start"] for r in primary);row["model_response_queued"]=max(r["response_queued"] for r in primary)
                    outbound=next((w["time"] for w in wire if w["direction"]=="server_to_agent" and w["frame"].get("message_id")==input_id and w["frame"]["type"]=="message.send"),None)
                    final=next((w["time"] for w in wire if w["direction"]=="agent_to_server" and w["frame"].get("message_id")==row["final_id"] and w["frame"]["type"]=="message.reply"),None)
                    row.update(server_send_proxy_observed=outbound,agent_final_proxy_observed=final)
                    phases={"total_ms":(row["client_observed"]-row["submitted"])*1000,"submit_to_model_ms":(row["model_request_start"]-row["submitted"])*1000,"post_return_to_model_ms":(row["model_request_start"]-row["submit_http_returned"])*1000,"model_service_ms":(row["model_response_queued"]-row["model_request_start"])*1000,"model_queued_to_db_ms":(db_result["commit_visible"]-row["model_response_queued"])*1000,"db_to_client_ms":(row["client_observed"]-db_result["commit_visible"])*1000,"db_visibility_interval_ms":(db_result["commit_visible"]-db_result["last_absent"])*1000}
                    if outbound is not None:phases["submit_to_server_send_observed_ms"]=(outbound-row["submitted"])*1000;phases["server_send_observed_to_model_ms"]=(row["model_request_start"]-outbound)*1000
                    if final is not None:phases["model_queued_to_agent_final_observed_ms"]=(final-row["model_response_queued"])*1000;phases["agent_final_observed_to_db_ms"]=(db_result["commit_visible"]-final)*1000
                    row["phases"]=phases
                    if index>=0:rows.append(row)
                connection.close();assert not proxy_errors,proxy_errors
                log.flush();log.seek(0);shim_lines=[line.strip() for line in log if "TEST_WS_NODELAY" in line]
                if case.get("server_ws_nodelay") is not None:assert any(f"after={case['server_ws_nodelay']} status=0" in line for line in shim_lines),"server WS shim did not observe socket"
                summary={name:{"p50":percentile([r["phases"][name] for r in rows],.5),"p95":percentile([r["phases"][name] for r in rows],.95)} for name in rows[0]["phases"]}
                result={"case":case,"count":len(rows),"failures":0,"model_socket_nodelay":sorted({r["socket_nodelay"] for r in model_records}),"server_ws_socket_observations":shim_lines,"summary_ms":summary,"rows":rows}
                (output/"result.json").write_text(json.dumps(result,indent=2)+"\n");print(json.dumps({k:v for k,v in result.items() if k!="rows"}),flush=True);return result
        finally:
            for process in [agent,server]:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:await asyncio.to_thread(process.wait,8)
                    except subprocess.TimeoutExpired:process.kill();await asyncio.to_thread(process.wait)
            if proxy_server:proxy_server.close();await proxy_server.wait_closed()
            log.close();agent_log.close()
            if runner:await runner.cleanup()
            if raw_server:raw_server.close();await raw_server.wait_closed()


async def main(args):
    args.out.mkdir(parents=True,exist_ok=True)
    shim=args.out/"server_nodelay_probe.so"
    subprocess.run(["cc","-shared","-fPIC","-O2","-Wall","-Wextra","-o",str(shim),str(Path(__file__).parent/"fixtures/latency/server_nodelay_probe.c"),"-ldl"],check=True)
    cases=[
        {"name":"direct_aiohttp_default","model":"aiohttp_default"},
        {"name":"proxy_aiohttp_default","model":"aiohttp_default","proxy":True},
        {"name":"direct_model_split_nodelay_off","model":"raw_split","model_nodelay":0},
        {"name":"direct_model_split_nodelay_on","model":"raw_split","model_nodelay":1},
        {"name":"direct_model_joined_nodelay_off","model":"raw_joined","model_nodelay":0},
        {"name":"direct_aiohttp_server_ws_nodelay_off","model":"aiohttp_default","server_ws_nodelay":0},
        {"name":"direct_aiohttp_server_ws_nodelay_on","model":"aiohttp_default","server_ws_nodelay":1},
        {"name":"proxy_aiohttp_server_ws_nodelay_on","model":"aiohttp_default","server_ws_nodelay":1,"proxy":True},
    ]
    if args.python_baseline:
        cases.extend([{"name":"python_component_server_ws_nodelay_off","variant":"python","model":"aiohttp_default","server_ws_nodelay":0,"n":12},{"name":"python_component_server_ws_nodelay_on","variant":"python","model":"aiohttp_default","server_ws_nodelay":1,"n":12}])
    if args.cases:cases=[case for case in cases if case["name"] in args.cases]
    results=[]
    for case in cases:
        try:results.append(await run_case(args,case,shim))
        except Exception as error:
            result={"case":case,"error":str(error)};results.append(result);print(json.dumps(result),flush=True)
    report={"agent_binary_sha256":hashlib.sha256(args.binary.read_bytes()).hexdigest(),"server_binary_sha256":hashlib.sha256(args.server_binary.read_bytes()).hexdigest(),"model_delay_ms":args.model_delay_ms,"results":[{k:v for k,v in r.items() if k!="rows"} for r in results],"limitations":["No Agent code or binary changes. Server shim is test-only runtime socket control, not a production fix.","All times share harness monotonic clock. model response queued is application-write completion, not peer receipt.","Proxy timestamps observe frames at the proxy and alter TCP topology; direct cases remain the causal baseline.","SQLite commit visibility is bounded by last-absent/first-present read, not exact internal transaction timing.","Synthetic localhost workload; no packet capture or proof of a specific kernel ACK timer.","Original Python is component integration, not production GatewayRunner; initial response can add model calls."]}
    (args.out/"summary.json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))
    assert all("error" not in result for result in results),"one or more stage cases failed"


if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,default=ROOT/"hermes-rust-core/results/stream-release/orialis_agent");p.add_argument("--server-binary",type=Path,default=ROOT/"orialis/target/release/orialis-server");p.add_argument("--out",type=Path,default=ROOT/"hermes-rust-core/results/transport-stage-probe");p.add_argument("--iterations",type=int,default=20);p.add_argument("--model-delay-ms",type=float,default=5);p.add_argument("--python-baseline",action="store_true");p.add_argument("--python",type=Path,default=Path("/tmp/hermes-full-env/gen-875da7f9ccb44ec6abe72396905579c3/venv/bin/python"));p.add_argument("--cases",nargs="*");asyncio.run(main(p.parse_args()))
