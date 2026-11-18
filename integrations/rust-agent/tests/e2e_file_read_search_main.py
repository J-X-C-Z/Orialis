#!/usr/bin/env python3
"""Actual owner-authenticated Server/mobile -> bounded read, extraction and search contract.
Synthetic accounts, files, and controlled model only. No deployment.
"""
import argparse,asyncio,base64,hashlib,json,os,shutil,sqlite3,subprocess,tempfile,time,urllib.request
from pathlib import Path
from aiohttp import web
import websockets
from e2e_workspace import ROOT,port
TOKEN='synthetic-full-lifecycle-token'
def api(base,method,path,body=None):
 req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json','Authorization':'Bearer '+TOKEN})
 with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
async def main(a):
 checks=[];calls=[];events=[]
 with tempfile.TemporaryDirectory(prefix='orialis-full-chain-') as name:
  d=Path(name);binary=d/'agent';shutil.copy2(a.binary,binary);sha=hashlib.sha256(binary.read_bytes()).hexdigest()
  export=d/'export';export.mkdir()
  (export/'bom.txt').write_bytes(b'\xef\xbb\xbffirst\r\n\r\nlast')
  (export/'hits.txt').write_text('hit\nhit\nhit\n')
  (export/'raw.txt').write_text('original')
  (export/'src').mkdir();(export/'src/new.py').write_text('new');(export/'old.rs').write_text('old')
  os.utime(export/'src/new.py',(2000,2000));os.utime(export/'old.rs',(1000,1000))
  (d/'outside').write_text('private');os.link(d/'outside',export/'hard');os.symlink(d/'outside',export/'link')
  (export/'.env').write_text('SYNTHETIC_SECRET=private')
  fixtures=json.loads((Path(__file__).parent/'fixtures/local_file_read_search/upstream.json').read_text())
  for fixture in fixtures['fixtures']:(export/fixture['name']).write_bytes(base64.b64decode(fixture['base64']))
  plans={
   'unread_guard':[('write_file',{'path':'raw.txt','content':'must fail'})],
   'bom':[('read_file',{'path':'bom.txt','limit':2}),('read_file',{'path':'bom.txt','offset':3,'limit':2})],
   'notebook':[('read_file',{'path':'notebook_0.ipynb'})],
   'docx':[('read_file',{'path':'paragraphs.docx'})],
   'search':[('search_files',{'pattern':'hit','path':'hits.txt','limit':2}),('search_files',{'pattern':'hit','path':'hits.txt','limit':2,'offset':2}),('search_files',{'pattern':'hit','path':'hits.txt','limit':3})],
   'globs':[('search_files',{'target':'files','pattern':'**/*.{rs,py}','order':'modified'})],
   'links':[('search_files',{'target':'files','pattern':'*'})],
   'document_guard':[('write_file',{'path':'paragraphs.docx','content':'must fail'})],
   'stale':[('read_file',{'path':'raw.txt'}),('write_file',{'path':'raw.txt','content':'must fail'})],
   'write':[('read_file',{'path':'raw.txt'}),('write_file',{'path':'raw.txt','content':'approved'})],
  }
  def validate(label,index,outcome):
   if label in ['unread_guard','document_guard'] or label=='stale' and index==1:
    assert isinstance(outcome.get('error'),str) and outcome['error'],(label,outcome);return
   assert 'error' not in outcome and outcome.get('success') is not False,(label,outcome)
   if label=='bom':
    assert outcome['content']==['1|first\n2|\n','3|last\n'][index],outcome
    assert outcome['complete_read']==(index==1),outcome
   elif label in ['notebook','docx']:
    assert outcome['extracted_document'] and not outcome['complete_read'] and outcome['extraction_complete'],outcome
    assert ('Overview' if label=='notebook' else 'Hello 日本語') in outcome['content']
   elif label=='search':
    assert len(outcome['matches'])==[2,1,3][index],outcome
    assert outcome['next_offset']==[2,None,None][index],outcome
    assert not outcome['incomplete'],outcome
   elif label=='globs':assert [v['path'] for v in outcome['matches']]==['src/new.py','old.rs'],outcome
   elif label=='links':assert not {'hard','link','.env'} & {v['path'] for v in outcome['matches']},outcome
   elif label=='write' and index==1:assert outcome['verified'],outcome
  async def model(request):
   payload=await request.json();calls.append(payload);messages=payload['messages'];at=max(i for i,m in enumerate(messages) if m['role']=='user');label=messages[at]['content'];tool_messages=[m for m in messages[at:] if m['role']=='tool']
   names={t['function']['name']:t['function'] for t in payload.get('tools',[])}
   assert names['search_files']['parameters']['properties']['order']['enum']==['discovery','modified']
   if tool_messages:
    validate(label,len(tool_messages)-1,json.loads(tool_messages[-1]['content']))
    if label=='stale' and len(tool_messages)==1:(export/'raw.txt').write_text('external change')
   if len(tool_messages)<len(plans[label]):
    name,arguments=plans[label][len(tool_messages)]
    call={'index':0,'id':'files-'+label+'-'+str(len(tool_messages)),'type':'function','function':{'name':name,'arguments':json.dumps(arguments)}}
    delta={'role':'assistant','tool_calls':[call]};finish='tool_calls'
   else:delta={'role':'assistant','content':'Verified '+label};finish='stop'
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
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--interactions','--local-tools-json',json.dumps({'root':str(export),'write':'ask','execute':'deny'})]
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
    for index,label in enumerate(plans):
     await send('local-chat','file-input-'+str(index),label)
     if label=='write':
      request=None
      while request is None:
       envelope=json.loads(await asyncio.wait_for(mobile.recv(),10));event=envelope.get('payload',{}).get('event',{})
       if event.get('type'):events.append(event)
       if event.get('type')=='approval.request':request=event
      assert (export/'raw.txt').read_text()=='external change'
      await mobile.send(json.dumps({'version':1,'type':'event','request_id':request['request_id'],'payload':{'kind':'approval.response','conversationId':'local-chat','decision':'once'}}))
     responses=await finals('local-chat',index+1);final=responses[-1]
     assert final['content']=='Verified '+label,final
     if label in ['unread_guard','document_guard']:assert (export/'raw.txt').read_text()=='original'
     if label=='stale':assert (export/'raw.txt').read_text()=='external change'
     if label=='write':assert (export/'raw.txt').read_text()=='approved'
     checks.append(label+' through real Server/provider tool round-trip')
    checks.append('read/search schemas reached actual provider, writes remained exact mobile approval guarded')
    agent.terminate();assert agent.wait(timeout=5)==0;agent=None
    checks.append('SIGTERM cleanly stopped the connected Agent and drained journals')
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner and controlled model; actual Server/mobile approval, confined native read/search/extraction and write guards. No Gitignore, PDF/OCR, or upstream byte-for-byte document formatting parity claim.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/next-file-read-search/main-e2e.json');asyncio.run(main(p.parse_args()))
