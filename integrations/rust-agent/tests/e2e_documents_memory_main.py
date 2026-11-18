#!/usr/bin/env python3
"""True owner-authenticated Orialis Server -> current Rust Agent lifecycle.
Synthetic accounts, files, and controlled model only. No deployment.
"""
import argparse,asyncio,hashlib,json,os,shutil,sqlite3,subprocess,tempfile,time,urllib.request
from pathlib import Path
from aiohttp import web
import websockets
import aiohttp
from reportlab.pdfgen import canvas
from docx import Document
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
  pdf=export/'evidence.pdf';page=canvas.Canvas(str(pdf));page.drawString(40,740,'PDF ACTUAL CONTENT');page.showPage();page.drawString(40,740,'SECOND PAGE ACTUAL CONTENT');page.save()
  docx=export/'evidence.docx';word=Document();word.add_paragraph('DOCX ACTUAL CONTENT 中文');word.save(docx)
  async def model(request):
   payload=await request.json();calls.append(payload)
   if not payload.get('tools'):
    answer=json.dumps({'summary':'# Screen fixture\n\nThis synthetic screen capture describes a test document task.','category':'other','video_detected':False})
   else:
    text=json.dumps(payload['messages'],ensure_ascii=False);assert 'PDF ACTUAL CONTENT' in text and 'SECOND PAGE ACTUAL CONTENT' in text and 'DOCX ACTUAL CONTENT 中文' in text,text
    answer='Verified actual PDF and DOCX contents.'
   if payload.get('stream'):
    response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
    for value in [{'choices':[{'index':0,'delta':{'role':'assistant','content':answer},'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]:await response.write(('data: '+json.dumps(value)+'\n\n').encode())
    await response.write(b'data: [DONE]\n\n');await response.write_eof();return response
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
   command=[str(binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','JXCZ_AOZORA_Hermes','--token',TOKEN,'--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--verify-owner','--expected-owner','full-owner','--session-context','--stream-events','--domain-tools','--attachments','--output-files','--artifact-root',str(export),'--documents','--pdf-program','/usr/bin/pdftotext']
   async def start():
    p=subprocess.Popen(command,stdout=al,stderr=subprocess.STDOUT)
    for _ in range(300):
     devices=await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices')
     if any(x['deviceId']=='JXCZ_AOZORA_Hermes' and x['online'] for x in devices['devices']):return p
     if p.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    raise RuntimeError('Agent startup timed out')
   async def create(conv):
    await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':conv,'title':'Fixture'});await asyncio.to_thread(api,base,'PUT',f'/api/v1/conversations/{conv}/agent-device',{'deviceId':'JXCZ_AOZORA_Hermes'})
   async def send(conv,mid,body):return await asyncio.to_thread(api,base,'POST',f'/api/v1/conversations/{conv}/messages',{'id':mid,'content':body})
   async def finals(conv,count=1):
    for _ in range(600):
     messages=await asyncio.to_thread(api,base,'GET',f'/api/v1/conversations/{conv}/messages?limit=500');found=[m for m in messages['items'] if m['role']=='assistant' and m['id'].startswith('final_')]
     if len(found)>=count:return found
     if agent.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    al.seek(0);raise AssertionError({'missing_finals':conv,'messages':messages,'log':al.read()})
   agent=await start();checks.append('real bearer owner verification and private account binding, development headers disabled')
   await create('documents-chat')
   form=aiohttp.FormData();form.add_field('files',pdf.read_bytes(),filename='evidence.pdf',content_type='application/pdf');form.add_field('files',docx.read_bytes(),filename='evidence.docx',content_type='application/octet-stream')
   async with aiohttp.ClientSession(headers={'Authorization':'Bearer '+TOKEN}) as http:
    async with http.post(base+'/api/v1/conversations/documents-chat/attachments',data=form) as response:
     upload=await response.json();assert response.status<400,upload
   attachments=upload['items'];assert len(attachments)==2,upload
   await asyncio.to_thread(api,base,'POST','/api/v1/conversations/documents-chat/messages',{'id':'documents-input','content':'Read both attached documents.','attachments':attachments})
   final=(await finals('documents-chat'))[0];assert final['content']=='Verified actual PDF and DOCX contents.'
   with sqlite3.connect(d/'agent.sqlite') as db:
    history=' '.join(r[0] for r in db.execute('SELECT body FROM messages'));assert 'PDF ACTUAL CONTENT' not in history and 'DOCX ACTUAL CONTENT' not in history
   checks+=['actual PDF and DOCX upload/download entered the real primary model request','multi-page Poppler and Rust Office parsing supplied real document bytes, not filename guesses','raw chat history retained attachment references rather than duplicating extracted source content']
   with sqlite3.connect(d/'server.sqlite') as db:before=db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
   endpoint=base+'/api/v1/memory/analyses/screen-input';evidence={'content':'A synthetic screen capture describes a document task.','sourceUrls':[]}
   async with aiohttp.ClientSession(headers={'Authorization':'Session synthetic-mobile-session'}) as http:
    async with http.post(endpoint,json=evidence) as response:submitted=await response.json();assert response.status<400,submitted
    for _ in range(600):
     async with http.get(endpoint) as response:result=await response.json()
     if result['status']!='analyzing':break
     await asyncio.sleep(.01)
    assert result['status']=='completed' and result['category']=='other' and result['videoStatus']=='none',result
    assert result['content'].startswith('# Screen fixture'),result
    old=len(calls)
    async with http.post(endpoint,json=evidence) as response:assert (await response.json())['status']=='completed'
    await asyncio.sleep(.1);assert len(calls)==old
   with sqlite3.connect(d/'server.sqlite') as db:assert db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==before
   assert len(calls)==2,calls
   checks+=['server memory HTTP request reached configured target Agent and new independent analysis handler','valid summary/category/videoStatus persisted without any chat-message write','same analysis evidence reused persisted result without another model call']
  except Exception:
   al.seek(0);sl.seek(0);print('AGENT LOG',al.read());print('SERVER LOG',sl.read()[-5000:]);raise
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5);await runner.cleanup()
  result={'passed':len(checks),'checks':checks,'provider_calls':len(calls),'binary_sha256':sha,'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'event_types':[v['type'] for v in events],'limitations':'Synthetic owner, true Server HTTP/Agent WS and actual document parsers; controlled primary/analysis model. No real Bilibili account/network or visual model quality claim.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/documents-memory-main-e2e.json');asyncio.run(main(p.parse_args()))
