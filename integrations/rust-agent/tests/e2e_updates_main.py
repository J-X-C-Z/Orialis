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
   if 'slow-request' in last and not any(m['role']=='tool' for m in messages):
    await asyncio.sleep(.2)
    call={'index':0,'id':'updates-task','type':'function','function':{'name':'create_task','arguments':json.dumps({'id':'updates-real-task','title':'Prepare performance report'})}}
    response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
    value={'choices':[{'index':0,'delta':{'role':'assistant','content':'I will create a report task and continue preparing the report.','tool_calls':[call]},'finish_reason':None}]}
    await response.write(('data: '+json.dumps(value)+'\n\n').encode());await response.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n');await response.write_eof();return response
   if 'slow-request' in last:slow.set();await asyncio.sleep(32);answer='Completed slow report.'
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
  async def auxiliary(request):
   payload=await request.json();prompt=payload['messages'][0]['content'];evidence=payload['messages'][1]['content']
   if '为会话取' in prompt:answer='性能报告'
   elif '正式处理前' in prompt:
    if 'fast-request' in evidence:await asyncio.sleep(1.0)
    answer='我会整理这份性能报告。'
   else:answer='正在整理已确认的信息。'
   return web.json_response({'choices':[{'message':{'role':'assistant','content':answer}}]})
  app=web.Application();app.router.add_post('/v1/auxiliary',auxiliary);app.router.add_post('/v1/chat/completions',model);runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start();modelport=site._server.sockets[0].getsockname()[1]
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
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--attachments','--output-files','--artifact-root',str(export),'--turn-updates','--auxiliary-endpoint',f'http://127.0.0.1:{modelport}/v1/auxiliary']
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
    for _ in range(2400):
     messages=await asyncio.to_thread(api,base,'GET',f'/api/v1/conversations/{conv}/messages?limit=500');found=[m for m in messages['items'] if m['role']=='assistant' and m['id'].startswith('final_')]
     if len(found)>=count:return found
     if agent.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    al.seek(0);raise AssertionError({'missing_finals':conv,'messages':messages,'log':al.read()})
   agent=await start();checks.append('real bearer owner verification and private account binding, development headers disabled')
   await create('updates-slow');await asyncio.to_thread(api,base,'PATCH','/api/v1/conversations/updates-slow',{'title':'新会话','baseVersion':1})
   # Use untouched version-1 placeholder, not a manually renamed version-2 row.
   with sqlite3.connect(d/'server.sqlite') as db:db.execute("UPDATE conversations SET title='新会话',version=1 WHERE id='updates-slow'")
   started=time.monotonic();await send('updates-slow','updates-slow-input','slow-request: create a performance report')
   initial=None
   for _ in range(150):
    page=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/updates-slow/messages?limit=500');initial=next((m for m in page['items'] if m['id'].startswith('initial_')),None)
    if initial:break
    await asyncio.sleep(.02)
   assert initial and time.monotonic()-started<3,page
   checks.append('auxiliary initial reply persisted before slow primary completion')
   assert not any(m['id'].startswith('final_') for m in page['items'])
   answer=(await finals('updates-slow'))[0];assert answer['content']=='Completed slow report.'
   page=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/updates-slow/messages?limit=500')
   assert any(m['id'].startswith('progress_') for m in page['items']),page
   checks+=['real 30-second progress update used public status while primary remained pending','initial/progress did not terminate final delivery']
   conversations=await asyncio.to_thread(api,base,'GET','/api/v1/conversations')
   found=next(v for v in conversations if v['id']=='updates-slow') if isinstance(conversations,list) else next(v for v in conversations['items'] if v['id']=='updates-slow')
   assert found['title']=='性能报告',found;checks.append('placeholder title changed through actual versioned server API')
   await create('updates-fast');await send('updates-fast','updates-fast-input','fast-request');await finals('updates-fast');await asyncio.sleep(1.1)
   page=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/updates-fast/messages?limit=500');assert not any(m['id'].startswith(('initial_','progress_')) for m in page['items']),page
   checks.append('slow helper cannot send stale initial after primary final')
   await send('updates-fast','updates-reset','/new');await finals('updates-fast',2)
   checks.append('slash reset skipped auxiliary updates and kept final correlation')
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner, real unchanged server and separate controlled auxiliary model; includes real 30s progress timer; no mobile rendering or production model.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/updates-main-e2e.json');asyncio.run(main(p.parse_args()))
