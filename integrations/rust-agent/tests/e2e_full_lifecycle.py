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
   payload=await request.json();calls.append(payload);messages=payload['messages'];last=next((m['content'] for m in reversed(messages) if m['role']=='user'),'')
   if isinstance(last,list):last=json.dumps(last)
   if 'slow-request' in last:slow.set();await asyncio.sleep(5);answer='LATE ANSWER MUST NOT COMMIT'
   elif 'artifact-request' in last:answer=f'Report ready.\nMEDIA:{document}'
   else:answer='Normal answer.'
   if payload.get('stream'):
    response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
    try:
     for value in [{'choices':[{'index':0,'delta':{'role':'assistant','content':answer},'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]:await response.write(('data: '+json.dumps(value)+'\n\n').encode())
     await response.write(b'data: [DONE]\n\n');await response.write_eof()
    except ConnectionError:pass
    return response
   return web.json_response({'choices':[{'message':{'role':'assistant','content':answer},'finish_reason':'stop'}]})
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
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--attachments','--output-files','--artifact-root',str(export)]
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
    async def collect():
     async for raw in mobile:
      envelope=json.loads(raw)
      if envelope['type']=='ping':await mobile.send(json.dumps({'version':1,'type':'pong','payload':{}}));continue
      if envelope.get('payload',{}).get('event'):events.append(envelope['payload']['event'])
    collector=asyncio.create_task(collect())
    await create('artifact-chat');await send('artifact-chat','artifact-input','artifact-request');final=(await finals('artifact-chat'))[0]
    assert final['content']=='Report ready.',final
    attachments=final.get('attachments') or [];assert len(attachments)==1,final
    attachment=attachments[0];url=attachment.get('downloadUrl') or attachment.get('download_url');assert url,attachment
    if url.startswith('/'):url=base+url
    req=urllib.request.Request(url,headers={'Authorization':'Bearer '+TOKEN})
    with urllib.request.urlopen(req) as response:assert response.read()==document.read_bytes()
    await asyncio.sleep(.2)
    kinds=[v['type'] for v in events];assert all(k in kinds for k in ['artifact.started','artifact.progress','artifact.completed']),kinds
    with sqlite3.connect(d/'agent.output.sqlite') as db:assert db.execute("SELECT COUNT(*) FROM output_files WHERE delivered_at IS NOT NULL").fetchone()[0]==1
    checks+=['final MEDIA marker produced a real owner-scoped attachment with exact downloadable bytes','artifact started/progress/completed traversed actual server/mobile sequenced stream','only actual final reply ACK marked artifact delivered']
    await create('cancel-chat');await send('cancel-chat','slow-input','slow-request');await asyncio.wait_for(slow.wait(),5)
    await send('cancel-chat','queued-input','normal queued request');before=time.monotonic();await send('cancel-chat','stop-input','/stop');cancelled=await finals('cancel-chat',3)
    elapsed=time.monotonic()-before;assert elapsed<3,elapsed
    assert any('已取消' in m['content'] for m in cancelled),cancelled
    await asyncio.sleep(5.1)
    with sqlite3.connect(d/'agent.sqlite') as db:
     assert db.execute("SELECT COUNT(*) FROM messages WHERE body LIKE '%LATE ANSWER%'").fetchone()[0]==0
     assert db.execute("SELECT COUNT(*) FROM context_cancelled_inputs").fetchone()[0]>=1
    checks+=['/stop bypassed busy conversation and cancelled running plus queued inputs','late model answer after cancellation never entered raw history']
    await send('cancel-chat','fresh-input','normal fresh request');await finals('cancel-chat',4)
    await send('cancel-chat','reset-input','/new');await finals('cancel-chat',5)
    before=len(calls);agent.terminate();agent.wait(timeout=5);agent=None;await asyncio.sleep(.1);agent=await start()
    await send('cancel-chat','after-restart-input','normal after restart');await finals('cancel-chat',6);assert len(calls)==before+1
    last=calls[-1]['messages'];assert len([m for m in last if m['role']=='user'])==1,last
    checks+=['cancelled conversation accepts later requests','/new preserved old history and restart used only new-generation context']
    collector.cancel();await asyncio.gather(collector,return_exceptions=True)
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner, real unchanged server/mobile WS/HTTP, controlled model; not production authorization or quality testing.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/full-lifecycle-main-e2e.json');asyncio.run(main(p.parse_args()))
