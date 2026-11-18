#!/usr/bin/env python3
"""Actual Core controls + pinned release Orialis server + original Python parser.
No model generation is claimed: this fixture starts with an empty Core session.
All local cooperating processes originate in this invocation.
"""
import argparse, asyncio, hashlib, importlib.util, json, os, socket, sqlite3, subprocess, tempfile, time, urllib.request
from pathlib import Path
import websockets
ROOT=Path(__file__).resolve().parents[2]
SHA='f9a064bf05b18265afd26905e7240777d4ce355c'
TOKEN='synthetic-session-commands-token'
def api(base,method,path,body=None):
    req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={'Content-Type':'application/json','Authorization':'Bearer '+TOKEN})
    with urllib.request.urlopen(req,timeout=3) as response:return json.load(response)
async def main(args):
    assert subprocess.check_output(['git','-C',str(ROOT/'orialis'),'rev-parse','HEAD'],text=True).strip()==SHA
    spec=importlib.util.spec_from_file_location('original_protocol',ROOT/'orialis/integrations/hermes/orialis/protocol.py');original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
    with tempfile.TemporaryDirectory(prefix='session-controls-real-') as temp:
        d=Path(temp)
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        base=f'http://127.0.0.1:{port}';wsbase=base.replace('http://','ws://')
        env=dict(os.environ,ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=str(port),ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='false',ORIALIS_DATABASE_URL=f'sqlite://{d}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(d/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,ORIALIS_AGENT_USER_ID='commands-owner',CARGO_HOME=str(ROOT/'.toolchain/cargo'),RUSTUP_HOME=str(ROOT/'.toolchain/rustup'),SESSION_COMMAND_SERVER=wsbase+'/api/v1/agent/ws',SESSION_COMMAND_FRAMES=str(d/'frames.json'))
        env['PATH']=str(ROOT/'.toolchain/cargo/bin')+os.pathsep+env['PATH']
        with (d/'server.log').open('w+') as log:
            server=subprocess.Popen([str(args.server_binary.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT);rust=None
            try:
                for _ in range(500):
                    try:await asyncio.to_thread(api,base,'GET','/api/v1/health');break
                    except OSError:
                        if server.poll() is not None:log.seek(0);raise RuntimeError(log.read())
                        await asyncio.sleep(.03)
                with sqlite3.connect(d/'server.sqlite') as db:
                    db.execute("INSERT INTO users(id,username,password_hash) VALUES('commands-owner','commands-owner','synthetic-no-login')")
                    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('commands-mobile','commands-owner',?,'2099-01-01T00:00:00Z')",(hashlib.sha256(b'synthetic-commands-mobile').hexdigest(),))
                await asyncio.to_thread(api,base,'POST','/api/v1/conversations',{'id':'commands-conversation','title':'Commands contract fixture'})
                async with websockets.connect(wsbase+'/api/v1/ws',additional_headers={'Authorization':'Session synthetic-commands-mobile'}) as mobile:
                    await mobile.send(json.dumps({'version':1,'type':'hello','payload':{}}));assert json.loads(await mobile.recv())['type']=='hello.ack'
                    command=['cargo','test','--manifest-path',str(ROOT/'hermes-rust-core/Cargo.toml'),'--test','session_commands','real_server_commands_fixture','--','--exact','--ignored','--nocapture']
                    rust=await asyncio.create_subprocess_exec(*command,env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.STDOUT)
                    for _ in range(3000):
                        devices=await asyncio.to_thread(api,base,'GET','/api/v1/agent/devices')
                        if any(x['deviceId']=='TE_ST_Rust' and x['online'] for x in devices['devices']):break
                        if rust.returncode is not None:raise AssertionError((await rust.communicate())[0].decode())
                        await asyncio.sleep(.03)
                    else:raise AssertionError('Rust fixture did not connect')
                    await asyncio.to_thread(api,base,'PUT','/api/v1/conversations/commands-conversation/agent-device',{'deviceId':'TE_ST_Rust'})
                    await asyncio.sleep(.1) # capabilities hello/ack before status route checks
                    events=[]
                    async def matching(predicate):
                        while True:
                            event=json.loads(await asyncio.wait_for(mobile.recv(),15));events.append(event)
                            payload=event.get('payload',{});payload=payload['event'] if isinstance(payload.get('event'),dict) else payload
                            if predicate(payload):return payload
                    await mobile.send(json.dumps({'version':1,'type':'event','request_id':'status-mobile','payload':{'kind':'session.status','conversationId':'commands-conversation'}}))
                    status=await matching(lambda p:p.get('kind')=='session.status' and p.get('requestId')=='status-mobile')
                    assert status['status']=='idle',status
                    for i,text in enumerate(['/sessions','/session history']):
                        rid=f'mobile-command-{i}'
                        await mobile.send(json.dumps({'version':1,'type':'event','request_id':rid,'payload':{'kind':'hermes.command','conversationId':'commands-conversation','command':text}}))
                        result=await matching(lambda p:p.get('kind')=='hermes.command.result' and p.get('id')==rid)
                        assert result['status']=='completed',result
                        data=json.loads(result['content']);assert data['scope']=='current_conversation'
                    # Normal persisted user commands exercise the production-safe
                    # reply persistence path, not the development no-anchor escape.
                    for i,text in enumerate(['/session info','/sessions']):
                        mid=f'stored-command-{i}'
                        await asyncio.to_thread(api,base,'POST','/api/v1/conversations/commands-conversation/messages',{'id':mid,'content':text})
                        for _ in range(500):
                            messages=await asyncio.to_thread(api,base,'GET','/api/v1/conversations/commands-conversation/messages?limit=100')
                            if any(m['role']=='assistant' and m.get('replyToMessageId')==mid for m in messages['items']):break
                            await asyncio.sleep(.02)
                        else:raise AssertionError(f'no persisted final for {mid}: {messages}')
                    for i in range(2):
                        event=await matching(lambda p:p.get('kind')=='hermes.command.result' and p.get('id')==f'extension-{i}')
                        assert event['status']=='completed',event
                    stdout,_=await rust.communicate();assert rust.returncode==0,stdout.decode()
                frames=json.loads((d/'frames.json').read_text())
                for pair in frames:
                    assert original.parse_message(original.encode(pair['request']))==pair['request']
                    assert original.parse_message(original.encode(pair['response']))==pair['response']
                assert frames[0]['request']['type']=='session.info' and frames[0]['request']['session_id']=='commands-conversation'
                assert frames[0]['response']['status']=='idle'
                with sqlite3.connect(d/'server.sqlite') as db:stored=db.execute("SELECT count(*) FROM messages WHERE role='assistant'").fetchone()[0]
                assert stored==2,stored
                report={'scope':'Actual Core control module, real fixed release Orialis server and original Python parser. Empty Core fixture, no model execution; not a full Agent binary test.','orialis_sha':SHA,'server_sha256':hashlib.sha256(args.server_binary.read_bytes()).hexdigest(),'checks_passed':7,'checks':['Mobile status -> server SessionInfo(conversation_id as session_id) -> Core idle -> typed SessionReply -> mobile status','Mobile /sessions -> real server message.send -> Core scoped list -> message.reply -> mobile command result','Mobile /session history -> real server message.send -> Core empty history -> message.reply -> mobile command result','command.request normalized reply accepted by actual extension validator and mobile broadcast','slash.command normalized command.reply accepted by actual extension validator and mobile broadcast','All actual inbound/outbound frames accepted by original Python protocol parser','Two ordinary stored user commands receive actual persisted server assistant rows'],'persisted_server_assistant_rows':stored,'frames':frames,'mobile_events':events,'cargo_test_output':stdout.decode(),'limitations':['Standalone test responder, not main Agent host integration.','Protocol SessionReply has no delivery ACK; successful correlated mobile result is not a persisted-message claim.','Two command extension requests are fixture inputs; their replies pass the real server. Actual mobile commands use message.send.','Mobile command requests have no stored user anchor: this fixture uses the fixed development-only exception. Source inspection indicates production rejects these unanchored replies; ordinary persisted user commands are separately validated.']}
                args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ('frames','mobile_events','cargo_test_output')},ensure_ascii=False,indent=2))
            finally:
                if rust and rust.returncode is None:rust.terminate();await rust.wait()
                server.terminate()
                try:server.wait(timeout=5)
                except subprocess.TimeoutExpired:server.kill();server.wait()
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--server-binary',type=Path,default=ROOT/'orialis/target/release/orialis-server');p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/session-commands-server.json');asyncio.run(main(p.parse_args()))
