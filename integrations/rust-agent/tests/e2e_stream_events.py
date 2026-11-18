#!/usr/bin/env python3
"""Actual Rust agent + real release Orialis server + controlled SSE provider.

A localhost forwarding WebSocket proxy records wire traffic and injects explicit
loss/capability faults. It is NOT the event validator: normal receipts, sequence
gaps, reply persistence and duplicate checks come from the real Orialis server.
All cooperating processes and sockets are created by this single invocation.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
import uuid

from aiohttp import web
import websockets

ROOT=Path(__file__).resolve().parents[2]
SHA="f9a064bf05b18265afd26905e7240777d4ce355c"


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1",0))
        return s.getsockname()[1]


def http(base,method,path,body=None):
    req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={"Content-Type":"application/json","x-orialis-device-id":"stream-e2e-client"})
    with urllib.request.urlopen(req,timeout=5) as response:
        return json.load(response)


async def until(predicate, timeout=15):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=predicate()
        if value:
            return value
        await asyncio.sleep(.01)
    raise AssertionError("timed out waiting for condition")


async def main(args):
    assert subprocess.check_output(["git","-C",str(args.orialis),"rev-parse","HEAD"],text=True).strip()==SHA
    spec=importlib.util.spec_from_file_location("original_protocol",args.orialis/"integrations/hermes/orialis/protocol.py")
    protocol=importlib.util.module_from_spec(spec);spec.loader.exec_module(protocol)
    checks=[];requests=[];events=[];server_frames=[];final_ack_forwarded={};connections=[];proxy_errors=[]
    control={"legacy":False,"drop_seq":None,"dropped":False,"withhold_final":False,"reject_preview":False,"rejected":False}
    retry_counts={}
    async def complete(request):
        data=await request.json();requests.append(data)
        user=next(m["content"] for m in reversed(data["messages"]) if m["role"]=="user")
        has_tool=any(m["role"]=="tool" for m in data["messages"])
        if user=="retry" and retry_counts.get(user,0)==0:
            retry_counts[user]=1
            return web.json_response({"error":"synthetic temporary error"},status=503)
        if user in {"slow","timeout"}:
            await asyncio.sleep(16.3 if user=="slow" else 2.0)
        tool=None
        if user in {"tools","tool_failure"} and not has_tool:
            tool={"id":"same-tool-id","type":"function","function":{"name":"memory","arguments":json.dumps({"action":"read","target":"user" if user=="tools" else "invalid"})}}
        answer="答:"+user
        if not data.get("stream"):
            message={"role":"assistant","content":None,"tool_calls":[tool]} if tool else {"role":"assistant","content":answer}
            return web.json_response({"choices":[{"message":message}]})
        response=web.StreamResponse(headers={"Content-Type":"text/event-stream"})
        try:
            await response.prepare(request)
        except ConnectionError:
            return response
        async def chunk(delta,finish=None):
            # Deliberately split UTF-8 network fragments.
            payload=("data: "+json.dumps({"choices":[{"index":0,"delta":delta,"finish_reason":finish}]},ensure_ascii=False)+"\n\n").encode()
            cut=max(1,len(payload)//2)
            await response.write(payload[:cut]);await response.write(payload[cut:])
        try:
            await chunk({"role":"assistant"})
            if tool:
                await chunk({"tool_calls":[dict(tool,index=0)]})
                await chunk({},"tool_calls")
            else:
                for character in answer:
                    await chunk({"content":character})
                    await asyncio.sleep(.012)
                await chunk({},"stop")
            await response.write(b"data: [DONE]\n\n")
            await response.write_eof()
        except (ConnectionError,RuntimeError):
            pass
        return response
    app=web.Application();app.router.add_post("/v1/chat/completions",complete)
    runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,"127.0.0.1",0);await site.start()
    model_port=site._server.sockets[0].getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="orialis-stream-e2e-") as td:
        directory=Path(td);base=f"http://127.0.0.1:{port()}";token="synthetic-stream-e2e-token"
        env=os.environ.copy();env.update(ORIALIS_ENV="development",ORIALIS_HOST="127.0.0.1",ORIALIS_PORT=base.rsplit(":",1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH="1",ORIALIS_DATABASE_URL=f"sqlite://{directory}/server.sqlite?mode=rwc",ORIALIS_UPLOAD_DIR=str(directory/"uploads"),ORIALIS_AGENT_DEVICE_TOKEN=token)
        log=(directory/"server.log").open("w+");server=subprocess.Popen([str(args.server_binary)],env=env,stdout=log,stderr=subprocess.STDOUT)
        agent=None;agent_log=(directory/"agent.log").open("w+")
        try:
            for _ in range(300):
                if server.poll() is not None:
                    log.seek(0);raise RuntimeError(log.read())
                try:
                    await asyncio.to_thread(http,base,"GET","/api/v1/health");break
                except OSError:
                    await asyncio.sleep(.03)
            await asyncio.to_thread(http,base,"GET","/api/v1/conversations")
            upstream_url=base.replace("http://","ws://")+"/api/v1/agent/ws"
            async def proxy(agent_ws):
                try:
                    async with websockets.connect(upstream_url,additional_headers={"Authorization":f"Bearer {token}"}) as upstream:
                        connections.append(agent_ws)
                        async def to_server():
                            async for raw in agent_ws:
                                frame=json.loads(raw);protocol.parse_message(frame)
                                if "event_id" in frame and frame["type"]!="agent.ack":
                                    events.append((time.monotonic(),frame))
                                    if frame["seq"]==control["drop_seq"] and not control["dropped"]:
                                        control["dropped"]=True;continue
                                await upstream.send(raw)
                        async def to_agent():
                            async for raw in upstream:
                                frame=json.loads(raw);server_frames.append((time.monotonic(),frame))
                                if frame["type"] in {"hello_ack","capabilities.ack"} and control["legacy"]:
                                    frame["capabilities"]=[];raw=json.dumps(frame)
                                if frame["type"]=="message.ack":
                                    if control["withhold_final"]:
                                        continue
                                    final_ack_forwarded[frame["message_id"]]=time.monotonic()
                                if frame["type"]=="agent.ack" and control["reject_preview"] and not control["rejected"]:
                                    event=next((e for _,e in reversed(events) if e.get("event_id")==frame["event_id"]),{})
                                    if event.get("type")=="agent.delta":
                                        frame["status"]="unknown";raw=json.dumps(frame);control["rejected"]=True
                                await agent_ws.send(raw)
                        tasks=[asyncio.create_task(to_server()),asyncio.create_task(to_agent())]
                        done,pending=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
                        for task in pending:task.cancel()
                        await asyncio.gather(*tasks,return_exceptions=True)
                        for task in done:
                            try:task.result()
                            except websockets.ConnectionClosed:pass
                except websockets.ConnectionClosed:
                    pass
                except Exception as error:
                    proxy_errors.append(repr(error))
            async with websockets.serve(proxy,"127.0.0.1",0,max_size=1_500_000) as proxy_server:
                proxy_port=proxy_server.sockets[0].getsockname()[1]
                command=[str(args.binary),"--server",f"ws://127.0.0.1:{proxy_port}/api/v1/agent/ws","--device","TE_ST_Rust","--token",token,"--db",str(directory/"agent.sqlite"),"--endpoint",f"http://127.0.0.1:{model_port}/v1/chat/completions","--model","controlled-sse","--stream-events"]
                def start(extra=()):return subprocess.Popen(command+list(extra),stdout=agent_log,stderr=subprocess.STDOUT)
                async def stop():
                    nonlocal agent
                    if agent and agent.poll() is None:
                        agent.terminate()
                        await asyncio.to_thread(agent.wait,5)
                async def ready(previous=0):
                    await until(lambda:len(connections)>previous)
                    await until(lambda:any(f["type"]=="capabilities.ack" for _,f in server_frames))
                    await asyncio.sleep(.05)
                async def send(text):
                    conv="stream-"+uuid.uuid4().hex;mid="input-"+uuid.uuid4().hex
                    await asyncio.to_thread(http,base,"POST","/api/v1/conversations",{"id":conv,"title":"Synthetic streaming test"})
                    await asyncio.to_thread(http,base,"PUT",f"/api/v1/conversations/{conv}/agent-device",{"deviceId":"TE_ST_Rust"})
                    await asyncio.to_thread(http,base,"POST",f"/api/v1/conversations/{conv}/messages",{"id":mid,"content":text})
                    return conv,mid
                async def final(conv,text,timeout=15):
                    deadline=time.monotonic()+timeout
                    while time.monotonic()<deadline:
                        rows=await asyncio.to_thread(http,base,"GET",f"/api/v1/conversations/{conv}/messages?limit=500")
                        found=[m for m in rows["items"] if m["role"]=="assistant" and m["content"]=="答:"+text]
                        if found:return found[-1]
                        await asyncio.sleep(.02)
                    agent_log.flush();agent_log.seek(0)
                    raise AssertionError(f"no persisted final for {text}: {agent_log.read()}")
                def run_frames(mid):return [(t,f) for t,f in events if f.get("reply_to")==mid]
                async def completed(mid,final_id):
                    return await until(lambda:next((f for _,f in run_frames(mid) if f["type"]=="agent.complete" and f["message_id"]==final_id),None))
                agent=start();await ready()
                # Gap is generated by actual server after the proxy drops seq 2.
                control["drop_seq"]=2
                conv,mid=await send("你好 streaming");stored=await final(conv,"你好 streaming");end=await completed(mid,stored["id"])
                await until(lambda:any(f.get("status")=="gap" and f.get("expected_seq")==2 for _,f in server_frames))
                unique={f["event_id"]:f for _,f in run_frames(mid)}
                deltas="".join(f["delta"] for f in sorted(unique.values(),key=lambda f:f["seq"]) if f["type"]=="agent.delta")
                assert deltas==stored["content"],deltas
                assert end["content"]==stored["content"]
                assert all(t>=final_ack_forwarded[f["message_id"]] for t,f in run_frames(mid) if f["type"]=="agent.complete")
                checks.append("actual SSE UTF-8 deltas, real server gap recovery, exact persisted completion ID after ACK")
                # Actual memory execution publishes lifecycle, including failure.
                for text,kind in [("tools","tool.completed"),("tool_failure","tool.failed")]:
                    conv,mid=await send(text);stored=await final(conv,text);await completed(mid,stored["id"])
                    frames=[f for _,f in run_frames(mid)]
                    assert any(f["type"]=="tool.started" for f in frames) and any(f["type"]==kind for f in frames)
                checks.append("real Core memory execution emits started/completed and failed tool lifecycle")
                # Separate concurrent conversations cannot mix runs or content.
                pairs=await asyncio.gather(send("parallel-a"),send("parallel-b"))
                run_ids=[]
                for (conv,mid),text in zip(pairs,["parallel-a","parallel-b"]):
                    stored=await final(conv,text);event=await completed(mid,stored["id"]);run_ids.append(event["run_id"])
                    assert event["content"]=="答:"+text
                assert len(set(run_ids))==2
                checks.append("parallel actual turns retain independent run IDs and final content")
                # No completion may escape while the persistence receipt is held.
                control["withhold_final"]=True
                conv,mid=await send("lost-ack");stored=await final(conv,"lost-ack");await asyncio.sleep(.15)
                assert not any(f["type"]=="agent.complete" for _,f in run_frames(mid))
                count=len(requests);previous=len(connections);control["withhold_final"]=False
                await connections[-1].close();await ready(previous);await completed(mid,stored["id"])
                assert len(requests)==count
                checks.append("lost final ACK reconnect replays stored reply and releases completion without inference")
                conv,mid=await send("retry");stored=await final(conv,"retry");await completed(mid,stored["id"])
                starts={f["run_id"] for _,f in run_frames(mid) if f["type"]=="agent.start"}
                assert len(starts)==2 and any(f["type"]=="agent.error" and f["code"]=="PROVIDER_RETRY" for _,f in run_frames(mid))
                checks.append("safe transient provider retry has a new run and closes the previous attempt")
                # 15-second real heartbeat, not accelerated fake clock.
                conv,mid=await send("slow");stored=await final(conv,"slow",25);await completed(mid,stored["id"])
                typing=[(t,f) for t,f in run_frames(mid) if f["type"]=="agent.typing" and f["typing"]]
                assert len(typing)>=2 and typing[-1][0]-typing[0][0]>=14
                checks.append("real 15-second heartbeat during provider wait under streaming 900-second default")
                # Optional preview rejection must not prevent actual final storage.
                control["reject_preview"]=True
                conv,mid=await send("reject-preview");stored=await final(conv,"reject-preview");assert control["rejected"]
                previous=len(connections);control["reject_preview"]=False
                await connections[-1].close();await ready(previous);await completed(mid,stored["id"])
                checks.append("injected event rejection leaves final persistence successful and outbox replayable")
                # Legacy peer forces non-SSE provider request even with CLI flag.
                control["legacy"]=True;previous=len(connections);await connections[-1].close();await ready(previous)
                before=len(events);conv,mid=await send("legacy");await final(conv,"legacy");await asyncio.sleep(.1)
                assert not requests[-1]["stream"] and not run_frames(mid)
                checks.append("legacy capability fallback uses non-stream provider and final-only protocol")
                # Deadline remains an actual total budget, independently configurable.
                await stop();control["legacy"]=False;previous=len(connections);agent=start(["--turn-timeout-secs","1"]);await ready(previous)
                conv,mid=await send("timeout")
                await until(lambda:any(f["type"]=="agent.error" and f.get("reply_to")==mid for _,f in events))
                await asyncio.sleep(.15)
                with sqlite3.connect(directory/"agent.sqlite") as db:
                    row=db.execute("SELECT state,frame FROM jobs WHERE id=?",("chat:"+mid,)).fetchone()
                assert row and json.loads(row[1])["code"]=="TURN_FAILED"
                checks.append("explicit one-second deadline terminates slow turn and emits correlated error")
                await stop()
                # Inspect durable global sequence across actual restart.
                with sqlite3.connect(directory/"agent.sqlite") as db:
                    last,epoch=db.execute("SELECT last_seq,session_id FROM gateway_event_state WHERE id=1").fetchone()
                unique={f["event_id"]:f for _,f in events}
                assert len({f["session_id"] for f in unique.values()})==1
                assert all(f["session_id"]==epoch for f in unique.values())
                seqs=sorted({f["seq"] for f in unique.values()});assert seqs==list(range(1,max(seqs)+1)) and last>=max(seqs)
                checks.append("device-global sequence and durable event epoch survive main-process restart")
                assert not proxy_errors,proxy_errors
        finally:
            if agent and agent.poll() is None:agent.terminate();await asyncio.to_thread(agent.wait,5)
            if server.poll() is None:server.terminate();await asyncio.to_thread(server.wait,5)
            log.close();agent_log.close()
    await runner.cleanup()
    report={"scope":"Actual Rust agent executable, release Orialis server (variant and hash recorded), original Python protocol parser; synthetic SSE model and explicit localhost proxy fault injection; no live model or mobile UI claim","server_variant":args.server_variant,"orialis_sha":SHA,"agent_binary_sha256":hashlib.sha256(args.binary.read_bytes()).hexdigest(),"server_binary_sha256":hashlib.sha256(args.server_binary.read_bytes()).hexdigest(),"checks_passed":len(checks),"checks":checks,"provider_requests":len(requests),"wire_event_transmissions":len(events)}
    if args.out:args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--binary",type=Path,default=ROOT/"hermes-rust-core/target/debug/orialis_agent");parser.add_argument("--server-binary",type=Path,default=ROOT/"orialis/target/release/orialis-server");parser.add_argument("--orialis",type=Path,default=ROOT/"orialis");parser.add_argument("--out",type=Path);parser.add_argument("--server-variant",default="original-fixed-sha")
    asyncio.run(main(parser.parse_args()))
