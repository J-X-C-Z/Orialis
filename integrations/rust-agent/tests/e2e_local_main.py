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
   if not tools:
    call={'index':0,'id':'write-local','type':'function','function':{'name':'write_file','arguments':json.dumps({'path':'created.txt','content':'Verified local contents 中文'})}}
    delta={'role':'assistant','tool_calls':[call]};finish='tool_calls'
   else:
    outcome=json.loads(tools[-1]['content'])
    if 'deny-write' in last:assert not outcome.get('success');answer='The file was not written.'
    else:assert outcome['success'] and outcome['verified'];answer='Created your file.\nMEDIA:'+outcome['media_reference']
    delta={'role':'assistant','content':answer};finish='stop'
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
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--attachments','--output-files','--artifact-root',str(export),'--interactions','--local-tools-json',json.dumps({'root':str(export),'write':'ask','execute':'deny'})]
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
    await create('local-chat')
    for index,decision in enumerate(['deny','once']):
     await send('local-chat','local-input-'+decision,'deny-write' if decision=='deny' else 'write-and-attach-file')
     request=None
     while request is None:
      envelope=json.loads(await asyncio.wait_for(mobile.recv(),10));event=envelope.get('payload',{}).get('event',{})
      if event.get('type')=='approval.request':request=event
     assert not (export/'created.txt').exists()
     await mobile.send(json.dumps({'version':1,'type':'event','request_id':request['request_id'],'payload':{'kind':'approval.response','conversationId':'local-chat','decision':decision}}))
     responses=await finals('local-chat',index+1);final=responses[-1]
     if decision=='deny':
      assert not (export/'created.txt').exists();assert not final['attachments'];checks.append('mobile denial produced no local write and no uploaded artifact')
     else:
      assert (export/'created.txt').read_text()=='Verified local contents 中文';assert len(final['attachments'])==1,final
      assert final['content']=='Created your file.',final
      attachment=final['attachments'][0];url=attachment.get('downloadUrl') or attachment.get('download_url');url=base+url if url.startswith('/') else url
      with urllib.request.urlopen(urllib.request.Request(url,headers={'Authorization':'Bearer '+TOKEN})) as response:assert response.read().decode()=='Verified local contents 中文'
      checks+=['one-use mobile approval executed the actual local filesystem write','generated private snapshot became a real downloadable Orialis attachment','final content removed MEDIA only after confirmed upload']
    assert len(calls)==4,calls
    agent.terminate();assert agent.wait(timeout=5)==0;agent=None
    checks.append('SIGTERM cleanly stopped the connected Agent and drained journals')
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner, true mobile approval, actual local write and Orialis upload; process sandbox behavior tested separately, not claimed by this file-write scenario.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/local-main-e2e.json');asyncio.run(main(p.parse_args()))
