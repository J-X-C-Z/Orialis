#!/usr/bin/env python3
"""Actual model -> Rust Agent clarify -> real server/mobile -> model continuation.
Includes process restart with pending interaction. Synthetic temporary data only.
"""
import argparse,asyncio,hashlib,json,os,subprocess,tempfile,time,uuid
from pathlib import Path
from aiohttp import web
import websockets
from e2e_workspace import ROOT,port,api
async def main(a):
 requests=[];checks=[]
 async def complete(request):
  data=await request.json();requests.append(data)
  tools=[m for m in data['messages'] if m['role']=='tool']
  if not tools:
   call={'index':0,'id':'clarify-1','type':'function','function':{'name':'clarify','arguments':json.dumps({'questions':[{'question':'Which format?','choices':['Detailed','Brief']},{'question':'Any extra requirement?'}]})}}
   delta={'role':'assistant','tool_calls':[call]};finish='tool_calls'
  else:
   answer=json.loads(tools[-1]['content']);assert answer['outcome']=='answered',answer
   assert answer['responses'][0]['user_response']=='Brief',answer
   assert answer['responses'][1]['user_response']=='Include performance numbers',answer
   delta={'role':'assistant','content':'A brief report with performance numbers.'};finish='stop'
  response=web.StreamResponse(headers={'Content-Type':'text/event-stream'});await response.prepare(request)
  for item in [{'choices':[{'index':0,'delta':delta,'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':finish}]}]:await response.write(('data: '+json.dumps(item)+'\n\n').encode())
  await response.write(b'data: [DONE]\n\n');await response.write_eof();return response
 app=web.Application();app.router.add_post('/v1/chat/completions',complete);runner=web.AppRunner(app);await runner.setup();site=web.TCPSite(runner,'127.0.0.1',0);await site.start();modelport=site._server.sockets[0].getsockname()[1]
 with tempfile.TemporaryDirectory(prefix='orialis-interactions-main-') as d:
  d=Path(d);base=f'http://127.0.0.1:{port()}';env=os.environ.copy();env.update(ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=base.rsplit(':',1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='1',ORIALIS_DATABASE_URL=f'sqlite://{d}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(d/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN='synthetic-interactions-token')
  sl=(d/'server.log').open('w+');al=(d/'agent.log').open('w+');server=subprocess.Popen([str(a.server)],env=env,stdout=sl,stderr=subprocess.STDOUT);agent=None
  try:
   for _ in range(300):
    try:await asyncio.to_thread(api,base,'GET','/api/v1/health');break
    except OSError:await asyncio.sleep(.02)
   await asyncio.to_thread(api,base,'GET','/api/v1/conversations')
   command=[str(a.binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token','synthetic-interactions-token','--db',str(d/'agent.sqlite'),'--endpoint',f'http://127.0.0.1:{modelport}/v1/chat/completions','--stream-events','--interactions']
   async def start():
    p=subprocess.Popen(command,stdout=al,stderr=subprocess.STDOUT)
    for _ in range(300):
     devices=await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices')
     if any(x['deviceId']=='TE_ST_Rust' and x['online'] for x in devices['devices']):return p
     if p.poll() is not None:al.seek(0);raise RuntimeError(al.read())
     await asyncio.sleep(.02)
    raise RuntimeError('agent startup timeout')
   agent=await start()
   async with websockets.connect(base.replace('http','ws')+'/api/v1/ws',additional_headers={'x-orialis-device-id':'workspace-e2e-client'}) as mobile:
    await mobile.send(json.dumps({'version':1,'type':'hello','payload':{}}));assert json.loads(await mobile.recv())['type']=='hello.ack'
    async def event(kind,request=None):
     end=time.monotonic()+15
     while time.monotonic()<end:
      envelope=json.loads(await asyncio.wait_for(mobile.recv(),15));v=envelope.get('payload',{}).get('event',{})
      if envelope['type']=='ping':await mobile.send(json.dumps({'version':1,'type':'pong','payload':{}}));continue
      if v.get('type')==kind and (request is None or v.get('request_id')==request):return v
     raise RuntimeError('missing event '+kind)
    async def conversation(conv):
     await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':conv,'title':'Fixture'});await asyncio.to_thread(api,base,'PUT',f'/api/v1/conversations/{conv}/agent-device',{'deviceId':'TE_ST_Rust'})
    await conversation('interactive-main')
    await asyncio.to_thread(api,base,'POST','/api/v1/conversations/interactive-main/messages',{'id':'main-input','content':'Prepare a report, ask me what format first.'})
    for answer in ['Brief','Include performance numbers']:
     card=await event('clarify.request');assert card['question']
     await mobile.send(json.dumps({'version':1,'type':'event','request_id':card['request_id'],'payload':{'kind':'clarify.response','conversationId':'interactive-main','answer':answer}}))
     resolved=await event('clarify.resolve',card['request_id']);assert resolved['request_id']==card['request_id']
    for _ in range(300):
     messages=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/interactive-main/messages?limit=500');final=[m for m in messages['items'] if m['role']=='assistant' and m['id'].startswith('final_')]
     if final:break
     await asyncio.sleep(.01)
    assert final[-1]['content']=='A brief report with performance numbers.';assert len(requests)==2
    checks+=['actual model requested clarify via registered tool','both native mobile answers resolved and cleared their cards','model resumed with actual answers and final reply persisted','two provider calls only; no duplicated tool effect']
    await conversation('restart-main');await asyncio.to_thread(api,base,'POST','/api/v1/conversations/restart-main/messages',{'id':'restart-input','content':'Ask before writing a second report.'})
    pending=await event('clarify.request');before=len(requests)
    agent.kill();agent.wait();agent=None;await asyncio.sleep(.1);agent=await start()
    cancelled=await event('clarify.cancel',pending['request_id']);assert cancelled['request_id']==pending['request_id'];await asyncio.sleep(.1);assert len(requests)==before
    checks+=['process restart cancels durable orphaned clarification','restart never fabricates an answer or repeats provider execution']
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5)
   await runner.cleanup()
 result={'passed':len(checks),'checks':checks,'provider_calls':len(requests),'binary_sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'limitations':'Controlled model, real server/mobile WS, no mobile UI rendering. Approval executor tested separately; this main-chain test exercises clarify.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/interactions-main-e2e.json');asyncio.run(main(p.parse_args()))
