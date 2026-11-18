#!/usr/bin/env python3
"""Final-binary feature-envelope and history/tool profile through a real server.
Controlled primary AND independent auxiliary model; synthetic account and files.
HTTP polling and synthetic mobile WS observations are not Flutter rendering.
"""
import argparse, asyncio, hashlib, json, math, os, re, sqlite3, statistics, subprocess, tempfile, time, uuid
from pathlib import Path
import aiohttp
from aiohttp import web
import psutil

ROOT=Path(__file__).resolve().parents[2]
TOKEN="synthetic-integrated-profile-token"
OWNER="integrated-profile-owner"

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def quantile(values,q):
    values=sorted(values)
    return values[min(len(values)-1,max(0,math.ceil(len(values)*q)-1))] if values else None

def snapshot(pid):
    root=psutil.Process(pid);processes=[root]+root.children(recursive=True)
    rss=threads=0;self_cpu=reaped_cpu=0.
    for process in processes:
        try:
            times=process.cpu_times();self_cpu+=times.user+times.system
            reaped_cpu+=getattr(times,"children_user",0)+getattr(times,"children_system",0)
            rss+=process.memory_info().rss;threads+=process.num_threads()
        except psutil.NoSuchProcess:pass
    return {"rss_bytes":rss,"running_cpu_seconds":self_cpu,"reaped_children_cpu_seconds":reaped_cpu,"cpu_seconds":self_cpu+reaped_cpu,"threads":threads}

def cpu_delta(before,after):return 1000*(after["cpu_seconds"]-before["cpu_seconds"])
def marker(text):
    match=re.search(r"BENCH_ID:([a-zA-Z0-9_-]+)",text)
    return match.group(1) if match else "unmatched"

def free_port():
    import socket
    with socket.socket() as s:s.bind(("127.0.0.1",0));return s.getsockname()[1]

async def main(a):
    a.out.mkdir(parents=True,exist_ok=False)
    primary_records=[];auxiliary_records=[];active_auxiliary=0
    async def primary(request):
        received=time.perf_counter();raw=await request.read();payload=json.loads(raw);messages=payload["messages"]
        last_index=max(i for i,m in enumerate(messages) if m["role"]=="user")
        content=messages[last_index]["content"];text=content if isinstance(content,str) else json.dumps(content,ensure_ascii=False)
        key=marker(text);tool="session_search" if "TOOL:session_search" in text else "list_tasks" if "TOOL:list_tasks" in text else None
        names=[t["function"]["name"] for t in payload.get("tools",[])]
        assert "web_search" not in names,"unconfigured web_search must not be advertised"
        call=tool is not None and not any(m["role"]=="tool" for m in messages[last_index+1:])
        if call:
            assert tool in names,(tool,names)
            args={"query":"no-matching-synthetic-entry","limit":5} if tool=="session_search" else {}
            call_value={"id":"call-"+key,"type":"function","function":{"name":tool,"arguments":json.dumps(args)}}
            message={"role":"assistant","content":None,"tool_calls":[call_value]};reason="tool_calls"
        else:message={"role":"assistant","content":"ANSWER:"+key};reason="stop"
        first_emission=None
        if payload.get("stream"):
            response=web.StreamResponse(headers={"Content-Type":"text/event-stream"});await response.prepare(request)
            for i in range(8):
                await asyncio.sleep(a.model_delay_ms/1000/8)
                if call:
                    delta={"tool_calls":[{"index":0,**call_value}]} if i==7 else {}
                else:
                    answer=message["content"];delta={"content":answer[i*len(answer)//8:(i+1)*len(answer)//8]}
                if first_emission is None and delta:first_emission=time.perf_counter()
                await response.write(("data: "+json.dumps({"choices":[{"index":0,"delta":delta,"finish_reason":None}]})+"\n\n").encode())
            await response.write(("data: "+json.dumps({"choices":[{"index":0,"delta":{},"finish_reason":reason}]})+"\n\ndata: [DONE]\n\n").encode());await response.write_eof()
        else:
            for _ in range(8):await asyncio.sleep(a.model_delay_ms/1000/8)
            response=web.json_response({"choices":[{"message":message,"finish_reason":reason}]});first_emission=time.perf_counter()
        queued=time.perf_counter()
        primary_records.append({"marker":key,"received_s":received,"response_queued_s":queued,"first_emission_s":first_emission,"actual_service_ms":(queued-received)*1000,"request_body_bytes":len(raw),"request_body_sha256":hashlib.sha256(raw).hexdigest(),"message_count":len(messages),"tool_schemas":len(names),"stream":bool(payload.get("stream")),"tool_requested":tool if call else None})
        return response
    async def auxiliary(request):
        nonlocal active_auxiliary
        active_auxiliary+=1;received=time.perf_counter();raw=await request.read();payload=json.loads(raw)
        try:
            prompt=payload["messages"][0]["content"];evidence=payload["messages"][-1]["content"]
            kind="title" if "为会话取" in prompt else "initial" if "正式处理前" in prompt else "progress"
            await asyncio.sleep(a.auxiliary_delay_ms/1000)
            content="合成性能测试" if kind=="title" else "正在处理请求。"
            queued=time.perf_counter();auxiliary_records.append({"marker":marker(evidence),"kind":kind,"received_s":received,"response_queued_s":queued,"actual_service_ms":(queued-received)*1000,"request_body_bytes":len(raw)})
            return web.json_response({"choices":[{"message":{"role":"assistant","content":content},"finish_reason":"stop"}]})
        finally:active_auxiliary-=1
    app=web.Application(client_max_size=64*1024*1024);app.router.add_post("/v1/chat/completions",primary);app.router.add_post("/v1/auxiliary",auxiliary)
    runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,"127.0.0.1",0);await site.start();model_port=site._server.sockets[0].getsockname()[1]
    all_rows=[];runs=[]
    try:
        for trial in range(a.trials):
            profiles=a.profiles if trial%2==0 else list(reversed(a.profiles))
            for profile in profiles:
                output=a.out/f"trial-{trial+1}-{profile}";output.mkdir()
                with tempfile.TemporaryDirectory(prefix="orialis-integrated-profile-") as temporary:
                    state=Path(temporary);root=state/"explicit-root";root.mkdir();(root/"fixture.txt").write_text("Synthetic read-only fixture\n")
                    base=f"http://127.0.0.1:{free_port()}";env=os.environ.copy()
                    for name in ["HERMES_CORE_API_KEY","HERMES_FALLBACK_API_KEY","ORIALIS_NEWS_PUBLISHER_TOKEN"]:env.pop(name,None)
                    env.update(ORIALIS_ENV="development",ORIALIS_HOST="127.0.0.1",ORIALIS_PORT=base.rsplit(":",1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH="false",ORIALIS_AGENT_USER_ID=OWNER,ORIALIS_DATABASE_URL=f"sqlite://{state}/server.sqlite?mode=rwc",ORIALIS_UPLOAD_DIR=str(state/"uploads"),ORIALIS_AGENT_DEVICE_TOKEN=TOKEN)
                    server_log=(output/"server.log").open("w");agent_log=(output/"agent.log").open("w")
                    server=subprocess.Popen([str(a.server)],env=env,stdout=server_log,stderr=subprocess.STDOUT);agent=None;collector=None
                    try:
                        async with aiohttp.ClientSession(headers={"Authorization":"Bearer "+TOKEN},timeout=aiohttp.ClientTimeout(total=60)) as client:
                            async def api(method,path,body=None):
                                async with client.request(method,base+path,json=body) as response:
                                    result=await response.json();assert response.status<400,(response.status,result);return result
                            for _ in range(500):
                                if server.poll() is not None:raise RuntimeError("server exited")
                                try:await api("GET","/api/v1/health");break
                                except (aiohttp.ClientError,OSError):await asyncio.sleep(.02)
                            with sqlite3.connect(state/"server.sqlite") as db:
                                db.execute("INSERT INTO users(id,username,password_hash) VALUES(?,?,?)",(OWNER,OWNER,"synthetic-no-login"))
                                db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('profile-mobile',?,?,'2099-01-01T00:00:00Z')",(OWNER,hashlib.sha256(b"synthetic-profile-mobile").hexdigest()))
                            command=[str(a.binary),"--server",base.replace("http://","ws://")+"/api/v1/agent/ws","--device","TE_ST_Rust","--token",TOKEN,"--db",str(state/"agent.sqlite"),"--endpoint",f"http://127.0.0.1:{model_port}/v1/chat/completions","--model","controlled-primary","--verify-owner","--expected-owner",OWNER,"--session-context"]
                            if profile=="full":
                                command += ["--stream-events","--domain-tools","--web-tools","--attachments","--documents","--pdf-program","/usr/bin/pdftotext","--interactions","--output-files","--artifact-root",str(root),"--scheduler","--local-tools-json",json.dumps({"root":str(root),"write":"ask","execute":"deny","programs":[]}),"--workspaces-json",json.dumps([{"path":str(root),"name":"Explicit synthetic root","terminal":False}]),"--turn-updates","--auxiliary-endpoint",f"http://127.0.0.1:{model_port}/v1/auxiliary","--auxiliary-model","controlled-independent-auxiliary"]
                            startup=time.perf_counter();agent=subprocess.Popen(command,env=env,stdout=agent_log,stderr=subprocess.STDOUT)
                            for _ in range(1000):
                                devices=await api("GET","/api/v1/agent/devices")
                                if any(d["deviceId"]=="TE_ST_Rust" and d["online"] for d in devices["devices"]):break
                                if agent.poll() is not None:raise RuntimeError("agent exited")
                                await asyncio.sleep(.01)
                            startup_ms=(time.perf_counter()-startup)*1000
                            observations={};active_by_conversation={};mobile_event_counts={}
                            ws=await client.ws_connect(base.replace("http://","ws://")+"/api/v1/ws",headers={"Authorization":"Session synthetic-profile-mobile"})
                            await ws.send_json({"version":1,"type":"hello","payload":{"capabilities":["stream.delta","agent.typing","agent.status","tool.timeline"]}})
                            assert (await ws.receive_json())["type"]=="hello.ack"
                            async def collect():
                                async for raw in ws:
                                    if raw.type!=aiohttp.WSMsgType.TEXT:continue
                                    message=json.loads(raw.data);now=time.perf_counter();kind=message.get("type");payload=message.get("payload",{})
                                    if kind=="ping":await ws.send_json({"version":1,"type":"pong","payload":{}});continue
                                    if kind=="message":
                                        content=payload.get("content","")
                                        if content.startswith("ANSWER:"):
                                            key=content[7:];observations.setdefault(key,{})["mobile_final_s"]=now
                                    event=payload.get("event",payload);event_kind=event.get("type",event.get("kind",kind));mobile_event_counts[event_kind]=mobile_event_counts.get(event_kind,0)+1
                                    if event_kind in ["agent.delta","stream.delta"]:
                                        conv=event.get("conversation_id") or payload.get("conversationId") or payload.get("conversation_id");key=active_by_conversation.get(conv)
                                        if key:observations.setdefault(key,{}).setdefault("mobile_first_delta_s",now)
                            collector=asyncio.create_task(collect())
                            async def conversation():
                                conv="bench-"+uuid.uuid4().hex;await api("POST","/api/v1/conversations",{"id":conv,"title":"新会话"});await api("PUT",f"/api/v1/conversations/{conv}/agent-device",{"deviceId":"TE_ST_Rust"});return conv
                            async def turn(conv,key,extra="",attachments=None):
                                observations[key]={};active_by_conversation[conv]=key;started=time.perf_counter();observations[key]["submitted_s"]=started
                                await api("POST",f"/api/v1/conversations/{conv}/messages",{"id":"input-"+uuid.uuid4().hex,"content":f"BENCH_ID:{key} {extra}","attachments":attachments or []})
                                polls=0
                                while time.perf_counter()-started<60:
                                    page=await api("GET",f"/api/v1/conversations/{conv}/messages?limit=500");polls+=1
                                    if any(m["role"]=="assistant" and m["content"]=="ANSWER:"+key for m in page["items"]):
                                        ended=time.perf_counter();observations[key]["http_final_s"]=ended
                                        return {"marker":key,"ok":True,"latency_ms":(ended-started)*1000,"polls":polls}
                                    if agent.poll() is not None:raise RuntimeError("agent exited during turn")
                                    await asyncio.sleep(.002)
                                raise TimeoutError("persisted correct final was not observed")
                            async def drain():
                                begun=time.perf_counter();stable=None
                                while time.perf_counter()-begun<5:
                                    with sqlite3.connect(state/"agent.sqlite") as db:
                                        pending=db.execute("SELECT COUNT(*) FROM jobs WHERE state='ready'").fetchone()[0]
                                        for table in ["gateway_event_outbox","gateway_event_completions"]:
                                            if db.execute("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)",(table,)).fetchone()[0]:pending+=db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                                    if pending==0 and active_auxiliary==0:
                                        if stable is None:stable=time.perf_counter()
                                        if time.perf_counter()-stable>=.1:return (time.perf_counter()-begun)*1000
                                    else:stable=None
                                    await asyncio.sleep(.01)
                                raise TimeoutError("durable outboxes did not drain")
                            await turn(await conversation(),f"warm-{trial}-{profile}");await drain()
                            idle_before=snapshot(agent.pid);await asyncio.sleep(a.idle_seconds);idle_after=snapshot(agent.pid)
                            run_info={"profile":profile,"trial":trial+1,"startup_online_ms":startup_ms,"idle_seconds":a.idle_seconds,"idle_cpu_ms":cpu_delta(idle_before,idle_after),"idle_rss_bytes":idle_after["rss_bytes"],"command":command,"server_variant":a.server_variant};runs.append(run_info)
                            async def workload(label,concurrency,count,extra="",shared_conversation=None):
                                convs=[shared_conversation]*count if shared_conversation else [await conversation() for _ in range(count)]
                                await drain();before=snapshot(agent.pid);server_before=snapshot(server.pid);pstart=len(primary_records);astart=len(auxiliary_records);samples=[];server_samples=[];stop=asyncio.Event()
                                async def sample():
                                    while not stop.is_set():samples.append(snapshot(agent.pid));server_samples.append(snapshot(server.pid));await asyncio.sleep(.02)
                                sampler=asyncio.create_task(sample());semaphore=asyncio.Semaphore(concurrency)
                                async def run(i):
                                    async with semaphore:
                                        key=f"{profile}-{trial}-{label}-{i}"
                                        try:return await turn(convs[i],key,extra)
                                        except Exception as error:return {"marker":key,"ok":False,"error":str(error)}
                                started=time.perf_counter();rows=await asyncio.gather(*(run(i) for i in range(count)));elapsed=time.perf_counter()-started;drain_ms=await drain()
                                after=snapshot(agent.pid);server_after=snapshot(server.pid);stop.set();await sampler
                                prs=primary_records[pstart:];ars=auxiliary_records[astart:];latencies=[r["latency_ms"] for r in rows if r["ok"]]
                                for row in rows:
                                    observed=observations.get(row["marker"],{});row["observations"]=observed
                                    if "mobile_final_s" in observed:row["mobile_final_ms"]=(observed["mobile_final_s"]-observed["submitted_s"])*1000
                                    if "mobile_first_delta_s" in observed:row["mobile_first_delta_ms"]=(observed["mobile_first_delta_s"]-observed["submitted_s"])*1000
                                    records=[r for r in prs if r["marker"]==row["marker"]]
                                    if records:row["submit_to_primary_ms"]=(min(r["received_s"] for r in records)-observed["submitted_s"])*1000;row["primary_actual_total_ms"]=sum(r["actual_service_ms"] for r in records)
                                expected=count*(2 if extra.startswith("TOOL:") else 1)
                                assert len(latencies)==count and len(prs)==expected,(label,rows,len(prs),expected)
                                metrics={"profile":profile,"trial":trial+1,"workload":label,"requests":count,"failures":count-len(latencies),"concurrency":concurrency,"wall_seconds":elapsed,"p50_ms":quantile(latencies,.5),"p95_ms":quantile(latencies,.95),"p99_ms":quantile(latencies,.99),"requests_per_second":count/elapsed,"agent_cpu_ms_per_request":cpu_delta(before,after)/count,"agent_reaped_children_cpu_ms_per_request":1000*(after["reaped_children_cpu_seconds"]-before["reaped_children_cpu_seconds"])/count,"agent_peak_rss_bytes":max([after["rss_bytes"]]+[s["rss_bytes"] for s in samples]),"server_cpu_ms_per_request":cpu_delta(server_before,server_after)/count,"server_peak_rss_bytes":max([server_after["rss_bytes"]]+[s["rss_bytes"] for s in server_samples]),"primary_calls":len(prs),"auxiliary_calls":len(ars),"primary_request_body_bytes":sum(r["request_body_bytes"] for r in prs),"auxiliary_request_body_bytes":sum(r["request_body_bytes"] for r in ars),"primary_actual_service_p50_ms":quantile([r["actual_service_ms"] for r in prs],.5),"drain_ms":drain_ms,"rows":rows,"primary_records":prs,"auxiliary_records":ars}
                                (output/f"{label}.json").write_text(json.dumps(metrics,indent=2)+"\n");all_rows.append(metrics);print(json.dumps({k:v for k,v in metrics.items() if k not in {"rows","primary_records","auxiliary_records"}}),flush=True)
                            if "short" in a.workloads:
                                await workload("fresh_text_sequential",1,a.iterations);await workload("fresh_text_concurrent4",4,a.iterations)
                            if "tools" in a.workloads:
                                await workload("session_search_tool",1,a.deep_iterations,"TOOL:session_search")
                                if profile=="full":await workload("domain_list_tasks_tool",1,a.deep_iterations,"TOOL:list_tasks")
                            if "history" in a.workloads and profile=="full":
                                conv=await conversation()
                                fixture=a.pdf_fixture
                                for i in range(a.history_documents):
                                    form=aiohttp.FormData();form.add_field("file",fixture.read_bytes(),filename=f"synthetic-{i}.pdf",content_type="application/pdf")
                                    async with client.post(base+f"/api/v1/conversations/{conv}/attachments",data=form,headers={"Idempotency-Key":f"history-attachment-{i}"}) as response:
                                        result=await response.json();assert response.status<400,(response.status,result)
                                    await turn(conv,f"history-setup-{trial}-{i}",attachments=result["items"])
                                await workload(f"history_{a.history_documents}_pdf",1,a.deep_iterations,shared_conversation=conv)
                            run_info["mobile_event_counts"]=mobile_event_counts;(output/"run.json").write_text(json.dumps(run_info,indent=2)+"\n")
                            collector.cancel();await asyncio.gather(collector,return_exceptions=True);collector=None;await ws.close()
                    finally:
                        if collector:collector.cancel();await asyncio.gather(collector,return_exceptions=True)
                        for process in [agent,server]:
                            if process and process.poll() is None:
                                process.terminate()
                                try:await asyncio.to_thread(process.wait,5)
                                except subprocess.TimeoutExpired:process.kill();await asyncio.to_thread(process.wait)
                        server_log.close();agent_log.close()
    finally:await runner.cleanup()
    pooled=[]
    for profile,workload in sorted({(r["profile"],r["workload"]) for r in all_rows}):
        group=[r for r in all_rows if (r["profile"],r["workload"])==(profile,workload)];count=sum(r["requests"] for r in group);latencies=[v["latency_ms"] for r in group for v in r["rows"]]
        pooled.append({"profile":profile,"workload":workload,"requests":count,"failures":sum(r["failures"] for r in group),"p50_ms":quantile(latencies,.5),"p95_ms":quantile(latencies,.95),"p99_ms":quantile(latencies,.99),"requests_per_second":count/sum(r["wall_seconds"] for r in group),"agent_cpu_ms_per_request":sum(r["agent_cpu_ms_per_request"]*r["requests"] for r in group)/count,"agent_peak_rss_bytes":max(r["agent_peak_rss_bytes"] for r in group),"server_cpu_ms_per_request":sum(r["server_cpu_ms_per_request"]*r["requests"] for r in group)/count,"primary_calls":sum(r["primary_calls"] for r in group),"auxiliary_calls":sum(r["auxiliary_calls"] for r in group),"primary_body_bytes_per_request":sum(r["primary_request_body_bytes"] for r in group)/count,"auxiliary_body_bytes_per_request":sum(r["auxiliary_request_body_bytes"] for r in group)/count,"mobile_final_p50_ms":quantile([v["mobile_final_ms"] for r in group for v in r["rows"] if "mobile_final_ms" in v],.5),"mobile_first_delta_p50_ms":quantile([v["mobile_first_delta_ms"] for r in group for v in r["rows"] if "mobile_first_delta_ms" in v],.5),"primary_actual_p50_ms":quantile([v["actual_service_ms"] for r in group for v in r["primary_records"]],.5)})
    report={"scope":"Same-final-binary base/full feature envelope, actual server HTTP/Agent WS and synthetic mobile WS subscriber; NOT Python equivalence or Flutter/WAN/live-model performance.","binary_sha256":sha(a.binary),"server_binary_sha256":sha(a.server),"server_variant":a.server_variant,"script_sha256":sha(Path(__file__)),"pdf_fixture_sha256":sha(a.pdf_fixture),"primary_nominal_delay_ms_per_call":a.model_delay_ms,"primary_sleep_intervals":8,"auxiliary_nominal_delay_ms_per_call":a.auxiliary_delay_ms,"http_poll_nominal_ms":2,"process_sampling_nominal_ms":20,"provider_requests_byte_equivalent":False,"summary":pooled,"runs":runs,"limitations":["Shared executor, no CPU pinning, quota isolation or confidence interval.","Full mode advertises additional tools and real helper model calls; this is feature cost, not same-payload algorithm speedup.","HTTP polling is a synthetic observation load; actual mobile WS receives events without this 2ms polling loop.","Process CPU includes reaped child counters (10ms granularity); sampled RSS may miss short Poppler children.","Actual model service duration is recorded separately from nominal sleeps.","No production model, WAN/TLS, Flutter render, cold disk, OCR, real-user files, deployment or push."]}
    (a.out/"summary.json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,required=True);p.add_argument("--server",type=Path,required=True);p.add_argument("--server-variant",required=True);p.add_argument("--out",type=Path,required=True);p.add_argument("--trials",type=int,default=3);p.add_argument("--iterations",type=int,default=40);p.add_argument("--deep-iterations",type=int,default=20);p.add_argument("--model-delay-ms",type=float,default=20);p.add_argument("--auxiliary-delay-ms",type=float,default=2);p.add_argument("--idle-seconds",type=float,default=2);p.add_argument("--history-documents",type=int,default=8);p.add_argument("--pdf-fixture",type=Path,default=ROOT/"hermes-rust-core/tests/fixtures/profiling/history-2pages.pdf");p.add_argument("--profiles",nargs="+",choices=["base","full"],default=["base","full"]);p.add_argument("--workloads",nargs="+",choices=["short","tools","history"],default=["short","tools","history"]);a=p.parse_args();assert a.iterations>0 and a.deep_iterations>0 and a.trials>0;asyncio.run(main(a))
