#!/usr/bin/env python3
"""True owner-authenticated Orialis Server -> current Rust Agent lifecycle.
Synthetic accounts, files, and controlled model only. No deployment.
"""
import argparse,asyncio,hashlib,json,os,shutil,sqlite3,subprocess,tempfile,time,urllib.request
from pathlib import Path
from aiohttp import web
import websockets
from e2e_workspace import ROOT,port
TOKEN='synthetic-full-lifecycle-token'
def api(base,method,path,body=None):
 req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json','Authorization':'Bearer '+TOKEN})
 with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
async def main(a):
 checks=[];calls=[];slow=asyncio.Event();events=[]
 with tempfile.TemporaryDirectory(prefix='orialis-full-chain-') as name:
  d=Path(name);binary=d/'agent';shutil.copy2(a.binary,binary);sha=hashlib.sha256(binary.read_bytes()).hexdigest()
  export=d/'export';export.mkdir();document=export/'report.txt';document.write_text('Actual artifact contents 中文\n')
  async def model(request):
   payload=await request.json();calls.append(payload);messages=payload['messages'];at=max(i for i,m in enumerate(messages) if m['role']=='user');last=messages[at]['content'];tools=[m for m in messages[at:] if m['role']=='tool']
   if last=='scheduled summary':answer='This is the scheduled summary.';delta={'role':'assistant','content':answer};finish='stop'
   elif not tools:
    call={'index':0,'id':'create-job','type':'function','function':{'name':'cronjob_manage','arguments':json.dumps({'action':'create','prompt':'scheduled summary','schedule':'in 2s','deliver':'origin'})}}
    delta={'role':'assistant','tool_calls':[call]};finish='tool_calls'
   else:
    outcome=json.loads(tools[-1]['content']);assert outcome['success'] is True,outcome
    assert outcome['persisted'] is True and outcome['execution']=='not_started',outcome
    delta={'role':'assistant','content':'Schedule saved. It has not run yet.'};finish='stop'
   if payload.get('stream'):
    response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
    for value in [{'choices':[{'index':0,'delta':delta,'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':finish}]}]:await response.write(('data: '+json.dumps(value)+'\n\n').encode())
    await response.write(b'data: [DONE]\n\n');await response.write_eof();return response
   return web.json_response({'choices':[{'message':delta,'finish_reason':finish}]})
  app=web.Application();app.router.add_post('/v1/chat/completions',model);runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start();modelport=site._server.sockets[0].getsockname()[1]
  base=f'http://127.0.0.1:{port()}';env=os.environ.copy();env.update(ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=base.rsplit(':',1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='false',ORIALIS_DATABASE_URL=f'sqlite://{d}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(d/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,ORIALIS_AGENT_USER_ID='full-owner')
  sl=(d/'server.log').open('w+');al=(d/'agent.log').open('w+');server=subprocess.Popen([str(a.server)],env=env,stdout=sl,stderr=subprocess.STDOUT);agent=None
  try:
   for _ in range(300):
    try:await asyncio.to_thread(api,base,'GET','/api/v1/health');break
    except OSError:await asyncio.sleep(.02)
   with sqlite3.connect(d/'server.sqlite') as db:
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('full-owner','full-owner','synthetic-no-login')")
    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('full-session','full-owner',?,'2099-01-01T00:00:00Z')",(hashlib.sha256(b'synthetic-mobile-session').hexdigest(),))
   assert (await asyncio.to_thread(api,base,'GET','/api/v1/auth/session'))['userId']=='full-owner'
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--attachments','--output-files','--artifact-root',str(export),'--interactions','--scheduler']
   async def start():
    p=subprocess.Popen(command,stdout=al,stderr=subprocess.STDOUT)
    for _ in range(300):
     devices=await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices')
     if any(x['deviceId']=='TE_ST_Rust' and x['online'] for x in devices['devices']):return p
     if p.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    raise RuntimeError('Agent startup timed out')
   async def create(conv):
    await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':conv,'title':'Fixture'});await asyncio.to_thread(api,base,'PUT',f'/api/v1/conversations/{conv}/agent-device',{'deviceId':'TE_ST_Rust'})
   async def send(conv,mid,body):return await asyncio.to_thread(api,base,'POST',f'/api/v1/conversations/{conv}/messages',{'id':mid,'content':body})
   async def finals(conv,count=1):
    for _ in range(600):
     messages=await asyncio.to_thread(api,base,'GET',f'/api/v1/conversations/{conv}/messages?limit=500');found=[m for m in messages['items'] if m['role']=='assistant' and m['id'].startswith('final_')]
     if len(found)>=count:return found
     if agent.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    al.seek(0);raise AssertionError({'missing_finals':conv,'messages':messages,'log':al.read()})
   agent=await start();checks.append('real bearer owner verification and private account binding, development headers disabled')
   async with websockets.connect(base.replace('http','ws')+'/api/v1/ws',additional_headers={'Authorization':'Session synthetic-mobile-session'}) as mobile:
    await mobile.send(json.dumps({'version':1,'type':'hello','payload':{}}));assert json.loads(await mobile.recv())['type']=='hello.ack'
    await create('scheduled-chat');await send('scheduled-chat','schedule-input','set-reminder-request')
    request=None
    while request is None:
     envelope=json.loads(await asyncio.wait_for(mobile.recv(),10));event=envelope.get('payload',{}).get('event',{})
     if event.get('type')=='approval.request':request=event
    assert 'scheduled summary' in json.dumps(request),request
    with sqlite3.connect(d/'agent.scheduler.sqlite') as db:assert db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0]==0
    checks.append('actual model cron tool requested exact approval before schedule persistence')
    await mobile.send(json.dumps({'version':1,'type':'event','request_id':request['request_id'],'payload':{'kind':'approval.response','conversationId':'scheduled-chat','decision':'once'}}))
    final=(await finals('scheduled-chat'))[0];assert final['content']=='Schedule saved. It has not run yet.'
    for _ in range(600):
     with sqlite3.connect(d/'agent.scheduler.sqlite') as db:acknowledged=db.execute("SELECT COUNT(*) FROM occurrences WHERE state='acknowledged'").fetchone()[0]
     if acknowledged:break
     await asyncio.sleep(.02)
    assert acknowledged==1
    with sqlite3.connect(d/'agent.delivery.sqlite') as db:assert db.execute("SELECT COUNT(*) FROM deliveries WHERE status='acknowledged'").fetchone()[0]==1
    delivered=None
    while delivered is None:
     envelope=json.loads(await asyncio.wait_for(mobile.recv(),5));events.append(envelope)
     if 'This is the scheduled summary.' in json.dumps(envelope):delivered=envelope
    checks+=['one-use mobile approval created a real persistent schedule','due occurrence ran the actual Core model once and saved its receipt','shared Agent WS delivered the fixed result and matched delivery ACK']
    page=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/scheduled-chat/messages?limit=500');assert not any(m['content']=='This is the scheduled summary.' for m in page['items'])
    checks.append('upstream delivery ACK observed as broadcast acceptance, not false message persistence')
    assert len(calls)==3,calls
    before=len(calls);agent.terminate();agent.wait(timeout=5);agent=None;await asyncio.sleep(.1);agent=await start();await asyncio.sleep(2.2);assert len(calls)==before
    checks.append('restart did not rerun completed schedule or provider/tool work')
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner, real unchanged server/mobile approval and delivery; controlled model; server does not persist delivered notifications.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/scheduler-main-e2e.json');asyncio.run(main(p.parse_args()))
