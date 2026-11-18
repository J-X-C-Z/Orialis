#!/usr/bin/env python3
"""Real mobile WS -> unchanged Orialis Server -> Rust Agent -> local files/PTY.
Synthetic temporary data only. No browser, production server or credentials.
"""
import argparse,asyncio,base64,hashlib,json,os,socket,subprocess,tempfile,time,urllib.request,uuid
from pathlib import Path
import websockets
ROOT=Path(__file__).resolve().parents[2]
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def api(base,method,path,body=None,device='workspace-e2e-client'):
 req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json','x-orialis-device-id':device})
 with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
async def main(a):
 checks=[]
 with tempfile.TemporaryDirectory(prefix='orialis-workspace-chain-') as d:
  d=Path(d);root=d/'shared';root.mkdir();(root/'source.txt').write_text('real filesystem evidence 中文')
  base=f'http://127.0.0.1:{port()}';env=os.environ.copy();env.update(ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=base.rsplit(':',1)[1],ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='1',ORIALIS_DATABASE_URL=f'sqlite://{d}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(d/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN='synthetic-workspace-token')
  log=(d/'server.log').open('w+');server=subprocess.Popen([str(a.server)],env=env,stdout=log,stderr=subprocess.STDOUT);agent=None;agentlog=(d/'agent.log').open('w+')
  try:
   for _ in range(300):
    try:await asyncio.to_thread(api,base,'GET','/api/v1/health');break
    except OSError:await asyncio.sleep(.02)
   await asyncio.to_thread(api,base,'GET','/api/v1/conversations')
   cmd=[str(a.binary),'--server',base.replace('http','ws')+'/api/v1/agent/ws','--device','TE_ST_Rust','--token','synthetic-workspace-token','--db',str(d/'agent.sqlite'),'--mock','--workspaces-json',json.dumps([{'path':str(root),'name':'Fixture','terminal':True}])]
   env['SHELL']='/bin/sh';agent=subprocess.Popen(cmd,env=env,stdout=agentlog,stderr=subprocess.STDOUT)
   for _ in range(300):
    devices=await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices')
    if any(x['deviceId']=='TE_ST_Rust' and x['online'] for x in devices['devices']):break
    if agent.poll() is not None:agentlog.seek(0);raise RuntimeError(agentlog.read())
    await asyncio.sleep(.02)
   await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':'workspace-conv','title':'Fixture'})
   await asyncio.to_thread(api,base,'PUT','/api/v1/conversations/workspace-conv/agent-device',{'deviceId':'TE_ST_Rust'})
   async def connect(device='workspace-e2e-client'):
    ws=await websockets.connect(base.replace('http','ws')+'/api/v1/ws',additional_headers={'x-orialis-device-id':device})
    await ws.send(json.dumps({'version':1,'type':'hello','request_id':'hello','payload':{}}));ack=json.loads(await ws.recv());assert ack['type']=='hello.ack';return ws,ack['payload']['connection_id']
   async def request(ws,op,**payload):
    request='req-'+uuid.uuid4().hex
    await ws.send(json.dumps({'version':1,'type':'event','request_id':request,'payload':{'kind':'workspace.request','conversationId':'workspace-conv','requestId':request,'op':op,**payload}}))
    while True:
     out=json.loads(await asyncio.wait_for(ws.recv(),20))
     if out['type']=='ping':await ws.send(json.dumps({'version':1,'type':'pong','payload':{}}));continue
     if out.get('payload',{}).get('requestId')==request:return out['payload']
   ws,identity=await connect();other,otheridentity=await connect()
   try:
    caps=await request(ws,'capabilities');assert caps['ok'] and len(caps['data']['workspaces'])==1;checks.append('actual mobile capabilities returns only explicitly configured root')
    read=await request(ws,'read',workspaceId='w0',path='source.txt');assert read['data']['text']=='real filesystem evidence 中文';checks.append('mobile request reads actual file through real server and Agent')
    upload=await request(ws,'upload',workspaceId='w0',path='new.txt',base64=base64.b64encode(b'new real file').decode());assert upload['ok'] and (root/'new.txt').read_bytes()==b'new real file'
    overwrite=await request(ws,'upload',workspaceId='w0',path='new.txt',base64=base64.b64encode(b'overwrite').decode());assert not overwrite['ok'];checks.append('exclusive upload creates once and refuses overwrite')
    assert not (await request(ws,'read',workspaceId='w0',path='../server.sqlite'))['ok'];checks.append('path escape rejected through full mobile route')
    opened=await request(ws,'terminal.open',workspaceId='w0',path='',columns=80,rows=24);assert opened['ok'],opened;tid=opened['data']['terminalId']
    denied=await request(other,'terminal.write',terminalId=tid,input='echo bad\n',_clientId=identity);assert not denied['ok'];checks.append('server overwrites forged client identity; second mobile socket cannot take terminal')
    assert (await request(ws,'terminal.write',terminalId=tid,input="printf 'PROOF-'; printf 'PTY\\n'\n"))['ok']
    output=''
    for _ in range(100):
     value=await request(ws,'terminal.read',terminalId=tid);assert value['ok'],value;output+=value['data']['output']
     if 'PROOF-PTY' in output:break
     await asyncio.sleep(.02)
    assert 'PROOF-PTY' in output;checks.append('real PTY executes and streams terminal output')
    assert not (await request(ws,'terminal.close_client',_clientId=otheridentity))['ok'];checks.append('mobile cannot invoke internal socket cleanup')
    await ws.close();await asyncio.sleep(.15)
    replacement,_=await connect()
    try:assert not (await request(replacement,'terminal.read',terminalId=tid,_clientId=identity))['ok']
    finally:await replacement.close()
    checks.append('mobile disconnect cleans terminal; reconnect cannot resurrect it')
   finally:await ws.close();await other.close()
  finally:
   if agent:agent.terminate();agent.wait(timeout=5)
   server.terminate();server.wait(timeout=5)
 result={'passed':len(checks),'checks':checks,'binary_sha256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'server_sha256':hashlib.sha256(a.server.read_bytes()).hexdigest(),'limitations':'Synthetic real mobile/server/Agent chain; no mobile UI rendering or production deployment.'}
 a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=ROOT/'hermes-rust-core/target/debug/orialis_agent');p.add_argument('--server',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/workspace-main-e2e.json');asyncio.run(main(p.parse_args()))
