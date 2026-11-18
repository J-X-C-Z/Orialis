#!/usr/bin/env python3
"""Real temporary Server + main Agent detached task lifecycle, controlled model only."""
import argparse, asyncio, hashlib, json, os, re, shutil, sqlite3, subprocess, tempfile, time
from pathlib import Path
from aiohttp import web
import websockets
from e2e_local_main import api, TOKEN
from e2e_workspace import ROOT, port

async def main(a):
 assert 0 <= a.benchmark_iterations <= 100
 checks=[];calls=[];child_calls=[];handles={};signals={};releases={};events=[];parent_latencies=[]
 parent_order_ready=asyncio.Event();parent_order_release=asyncio.Event();event_times={};benchmark=None
 with tempfile.TemporaryDirectory(prefix='orialis-background-main-') as name:
  d=Path(name);binary=d/'agent';shutil.copy2(a.binary,binary)
  async def model(request):
   payload=await request.json();calls.append(payload);messages=payload['messages'];child=messages[0]['content'].startswith('You are an isolated delegated assistant.')
   user=next(m['content'] for m in reversed(messages) if m['role']=='user');label=re.search(r'BGCASE:([a-z]+):END',user).group(1)
   if child:
    child_calls.append(label);assert 'PRIVATE_PARENT' not in json.dumps(messages)
    signals.setdefault(label,asyncio.Event()).set();await releases.setdefault(label,asyncio.Event()).wait()
    response={'role':'assistant','content':'CHILD_COMPLETED_'+label}
   else:
    schema=next(t['function'] for t in payload['tools'] if t['function']['name']=='delegate_task');assert schema['parameters']['properties']['background']['type']=='boolean'
    at=max(i for i,m in enumerate(messages) if m['role']=='user');receipts=[m for m in messages[at:] if m['role']=='tool']
    if not receipts:response={'role':'assistant','content':None,'tool_calls':[{'id':'dispatch-'+label,'type':'function','function':{'name':'delegate_task','arguments':json.dumps({'background':True,'tasks':[{'goal':'BGCASE:'+label+':END'}]})}}]}
    else:
     handles[label]=json.loads(receipts[-1]['content']);assert handles[label]['mode']=='background' and handles[label]['status']=='dispatched',handles[label]
     if label=='order':parent_order_ready.set();await parent_order_release.wait()
     response={'role':'assistant','content':'PARENT_RETURNED_'+label}
   finish='tool_calls' if response.get('tool_calls') else 'stop'
   if not payload.get('stream'):return web.json_response({'choices':[{'message':response,'finish_reason':finish}]})
   stream=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await stream.prepare(request);delta=dict(response)
   if 'tool_calls' in delta:delta['tool_calls']=[dict(t,index=i) for i,t in enumerate(delta['tool_calls'])]
   for item in [{'choices':[{'index':0,'delta':delta,'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':finish}]}]:await stream.write(('data: '+json.dumps(item)+'\n\n').encode())
   await stream.write(b'data: [DONE]\n\n');await stream.write_eof();return stream
  app=web.Application();app.router.add_post('/v1/chat/completions',model);runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start();mp=site._server.sockets[0].getsockname()[1]
  base='http://127.0.0.1:'+str(port());env=os.environ.copy();env.update(ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=base.rsplit(':',1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='false',ORIALIS_DATABASE_URL=f'sqlite://{d}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(d/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,ORIALIS_AGENT_USER_ID='full-owner')
  sl=(d/'server.log').open('w+');al=(d/'agent.log').open('w+');server=subprocess.Popen([str(a.server)],env=env,stdout=sl,stderr=subprocess.STDOUT);agent=None;collector=None
  command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Background','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{mp}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--delegation','--delegation-background','--stream-events','--inbound-deliveries']
  async def eventually(check,timeout=12):
   began=time.monotonic()
   while time.monotonic()-began<timeout:
    value=await check()
    if value:return value
    await asyncio.sleep(.025)
   raise AssertionError('condition timed out')
  async def start():
   p=subprocess.Popen(command,env=env,stdout=al,stderr=subprocess.STDOUT)
   async def online():
    assert p.poll() is None,'Agent exited'
    return any(v['deviceId']=='TE_ST_Background' and v['online'] for v in (await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices'))['devices'])
   await eventually(online);return p
  async def stop(kill=False):
   nonlocal agent
   if kill:agent.kill()
   else:agent.terminate()
   code=await asyncio.to_thread(agent.wait,5)
   if not kill:assert code==0,code
   agent=None;await asyncio.sleep(.2)
  async def send(conv,mid,text):return await asyncio.to_thread(api,base,'POST',f'/api/v1/conversations/{conv}/messages',{'id':mid,'content':text})
  async def finals(conv,n):
   async def get():
    messages=(await asyncio.to_thread(api,base,'GET',f'/api/v1/conversations/{conv}/messages?limit=500'))['items'];rows=[m for m in messages if m['role']=='assistant' and m['id'].startswith('final_')];return rows if len(rows)>=n else None
   return await eventually(get)
  async def run(label):
   await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':'bg-'+label,'title':'Synthetic detached task'});await asyncio.to_thread(api,base,'PUT',f'/api/v1/conversations/bg-{label}/agent-device',{'deviceId':'TE_ST_Background'})
   started=time.monotonic();await send('bg-'+label,'input-'+label,'BGCASE:'+label+':END PRIVATE_PARENT');rows=await finals('bg-'+label,1);parent_latencies.append((time.monotonic()-started)*1000)
   assert rows[-1]['content']=='PARENT_RETURNED_'+label,rows
   await asyncio.wait_for(signals.setdefault(label,asyncio.Event()).wait(),5);assert not releases[label].is_set()
  def notification_key(label):
   with sqlite3.connect(d/'agent.delegation.sqlite') as db:return db.execute('SELECT notification_id FROM delegation_background WHERE batch=?',(handles[label]['delegation_id'],)).fetchone()[0]
  async def notification(label,partial=False):
   async def found():
    for event in events:
     body=json.dumps(event,ensure_ascii=False)
     if notification_key(label) in body and ('不确定' if partial else 'CHILD_COMPLETED_'+label) in body:return event
   return await eventually(found)
  async def drain(mobile):
   async for raw in mobile:
    now=time.monotonic_ns();event=json.loads(raw);events.append(event)
    payload=event.get('payload',{})
    if payload.get('kind')=='delivery.notification':event_times[payload.get('messageId')]=now
  def own_process():
   fields=Path(f'/proc/{agent.pid}/stat').read_text().rsplit(')',1)[1].split();status=Path(f'/proc/{agent.pid}/status').read_text()
   memory={line.split(':',1)[0]:int(line.split()[1])*1024 for line in status.splitlines() if line.startswith(('VmRSS:','VmHWM:'))}
   assert agent.poll() is None, 'Agent exited during observation'
   try:children=Path(f'/proc/{agent.pid}/task/{agent.pid}/children').read_text().split();children_error=None
   except OSError as error:children=None;children_error=str(error)
   return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),'memory':memory,'children':children,'children_observation_error':children_error}

  try:
   for _ in range(400):
    try:await asyncio.to_thread(api,base,'GET','/api/v1/health');break
    except OSError:await asyncio.sleep(.025)
   with sqlite3.connect(d/'server.sqlite') as db:
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('full-owner','full-owner','synthetic-no-login')");db.execute("INSERT INTO users(id,username,password_hash) VALUES('other-owner','other-owner','synthetic-no-login')")
    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('full-session','full-owner',?,'2099-01-01T00:00:00Z')",(hashlib.sha256(b'synthetic-mobile-session').hexdigest(),))
   agent=await start()
   async with websockets.connect(base.replace('http','ws')+'/api/v1/ws',additional_headers={'Authorization':'Session synthetic-mobile-session'}) as mobile:
    await mobile.send(json.dumps({'version':1,'type':'hello','payload':{}}));assert json.loads(await mobile.recv())['type']=='hello.ack';collector=asyncio.create_task(drain(mobile))
    await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':'bg-order','title':'Ordering fixture'});await asyncio.to_thread(api,base,'PUT','/api/v1/conversations/bg-order/agent-device',{'deviceId':'TE_ST_Background'})
    releases['order']=asyncio.Event();releases['order'].set()
    await send('bg-order','input-order','BGCASE:order:END PRIVATE_PARENT')
    await asyncio.wait_for(parent_order_ready.wait(),5);await asyncio.sleep(1.3)
    assert not any(notification_key('order') in json.dumps(e) for e in events)
    parent_order_release.set();await finals('bg-order',1);await notification('order')
    checks.append('immediate child completion cannot overtake blocked parent final; parent ACK releases the durable notification')
    await run('done');checks.append('background admission and parent final complete while child provider is still blocked; context remains isolated')
    releases['done'].set();await notification('done');checks.append('same main WS delivers bounded child result to authenticated mobile with inbound delivery enabled')
    async def acked():
     with sqlite3.connect(d/'agent.delivery.sqlite') as db:return db.execute("SELECT count(*) FROM deliveries WHERE status='acknowledged'").fetchone()[0]>=1
    await eventually(acked)
    before=(len(calls),len(child_calls));await send('bg-done','input-done','BGCASE:done:END PRIVATE_PARENT');await asyncio.sleep(.2);assert (len(calls),len(child_calls))==before
    await stop();agent=await start();await asyncio.sleep(1.3);assert (len(calls),len(child_calls))==before;checks.append('duplicate HTTP input and Agent restart do not repeat parent/child work or acknowledged notifications')
    page=(await asyncio.to_thread(api,base,'GET','/api/v1/conversations/bg-done/messages?limit=500'))['items'];assert not any('CHILD_COMPLETED_done' in m['content'] for m in page);checks.append('legacy received ACK is not falsely treated as persisted Server history')
    await run('stop');await send('bg-stop','stop-request','/stop');rows=await finals('bg-stop',2);assert any('已停止' in m['content'] for m in rows),rows;releases['stop'].set();await asyncio.sleep(1.3)
    assert not any(notification_key('stop') in json.dumps(e) for e in events);checks.append('explicit /stop cancels detached work even after the original parent turn ended and suppresses completion')
    await run('reset');await send('bg-reset','reset-request','/new');await finals('bg-reset',2);releases['reset'].set();await asyncio.sleep(1.3)
    assert not any(notification_key('reset') in json.dumps(e) for e in events);checks.append('/new generation fence prevents stale background notification')
    await run('crash');before=len(child_calls);await stop(kill=True);releases['crash'].set();agent=await start();await notification('crash',partial=True);assert len(child_calls)==before;checks.append('hard process death recovers interrupted completion without replaying the child model or tools')
    await run('revoked')
    with sqlite3.connect(d/'server.sqlite') as db:db.execute("UPDATE conversations SET user_id='other-owner' WHERE id='bg-revoked'")
    releases['revoked'].set();await asyncio.sleep(2.2);assert not any(notification_key('revoked') in json.dumps(e) for e in events)
    with sqlite3.connect(d/'agent.delivery.sqlite') as db:
     pending=db.execute("SELECT count(*) FROM deliveries WHERE json_extract(request,'$.target.conversation_id')='bg-revoked' AND status='pending'").fetchone()[0]
    assert pending==1;checks.append('conversation ownership revoked before delivery blocks notification and retains a pending result')
    with sqlite3.connect(d/'server.sqlite') as db:db.execute("UPDATE conversations SET user_id='full-owner' WHERE id='bg-revoked'")
    before=len(child_calls);await stop();agent=await start();await notification('revoked');assert len(child_calls)==before;checks.append('restored authorized conversation receives original retained result after reconnect, without regeneration')
    if a.benchmark_iterations:
     snapshots={'before':own_process()};samples=[];began=time.monotonic();before_calls=len(calls)
     for index in range(a.benchmark_iterations):
      label='bench'+chr(97+index//26)+chr(97+index%26)
      await run(label);released=time.monotonic_ns();releases[label].set();await notification(label)
      key=notification_key(label)
      samples.append({'iteration':index,'parent_final_ms':parent_latencies[-1],'child_release_to_mobile_notification_ms':(event_times[key]-released)/1e6})
     snapshots['after']=own_process();wall=time.monotonic()-began
     benchmark={'iterations':a.benchmark_iterations,'raw_samples':samples,'agent_snapshots':snapshots,'agent_cpu_ms_per_complete_task':(snapshots['after']['cpu_seconds']-snapshots['before']['cpu_seconds'])*1000/a.benchmark_iterations,'whole_driver_seconds':wall,'provider_calls':len(calls)-before_calls,'scope':'Warm actual main + original Server + controlled immediate provider, no child tools. CPU includes parent and child Agent work; driver time includes fixture REST/polling. Notification latency uses actual mobile collector timestamp after blocked child released, not polling detection time. Process memory includes preceding correctness scenarios; not per-phase peak, child process tree or isolated host.'}
    await stop();checks.append('SIGTERM drains detached lifecycle and journals cleanly')
  except Exception:
   print('OBSERVED EVENTS',json.dumps(events[-15:],ensure_ascii=False));
   al.seek(0);sl.seek(0);print('AGENT',al.read());print('SERVER',sl.read()[-5000:]);raise
  finally:
   parent_order_release.set()
   for event in releases.values():event.set()
   if collector:collector.cancel()
   if agent:agent.terminate();await asyncio.to_thread(agent.wait,5)
   server.terminate();await asyncio.to_thread(server.wait,5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'benchmark':benchmark,'child_calls':child_calls,'parent_final_latency_ms':parent_latencies,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'limitations':'Actual temporary Server/main/mobile protocol and synthetic model; notifications are not persisted by legacy Server. No production credentials, live provider quality, Flutter UI, automatic parent model wake or arbitrary side-effect exactly-once claim. Latencies are diagnostic, not controlled A/B performance.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--server',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--benchmark-iterations',type=int,default=0);asyncio.run(main(p.parse_args()))
