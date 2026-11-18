#!/usr/bin/env python3
"""Local-only real WebSocket + HTTP provider contract checks. No live account/API usage."""
import asyncio, json, os, tempfile, time, sys, argparse
from pathlib import Path
import psutil
import websockets
from aiohttp import web

async def main(binary):
    requests=[];connections=asyncio.Queue();release=asyncio.Event();crash_release=asyncio.Event();seen_auth=[]
    async def complete(request):
        data=await request.json();requests.append(data)
        messages=data['messages'];user=next((m['content'] for m in reversed(messages) if m['role']=='user'),'')
        if data['model']=='fake-vision':
            assert 'tools' not in data
            assert len(messages)==2 and isinstance(user,list)
            answer={'role':'assistant','content':json.dumps({'summary':'# 本地测试\n\n截图内容的测试摘要。','category':'ai','video_detected':False},ensure_ascii=False)}
        elif user=='crash':
            await crash_release.wait();answer={'role':'assistant','content':'crash done'}
        elif user=='slow':
            await release.wait();answer={'role':'assistant','content':'slow done'}
        elif user=='remember' and not any(m['role']=='tool' for m in messages):
            answer={'role':'assistant','content':None,'tool_calls':[{'id':'tool-1','type':'function','function':{'name':'memory','arguments':json.dumps({'target':'user','action':'add','content':'喜欢中文回答'})}}]}
        else: answer={'role':'assistant','content':'答:'+str(user)}
        return web.json_response({'choices':[{'message':answer}]})
    app=web.Application();app.router.add_post('/v1/chat/completions',complete);runner=web.AppRunner(app);await runner.setup();http=web.TCPSite(runner,'127.0.0.1',0);await http.start();hp=http._server.sockets[0].getsockname()[1]
    async def ws_handler(ws):
        seen_auth.append(ws.request.headers.get('Authorization'))
        hello=json.loads(await ws.recv());assert hello['type']=='hello' and hello['version']==1
        assert set(hello['capabilities'])=={'messages','ack','reconnect','device_auth','memory.analyze'}
        assert 'attachments' not in hello['capabilities']
        await ws.send(json.dumps({'version':1,'type':'hello_ack','capabilities':['messages','memory.analyze']}))
        caps=json.loads(await ws.recv());assert caps['type']=='capabilities.hello' and 'memory.analyze' in caps['capabilities']
        await ws.send(json.dumps({'version':1,'type':'capabilities.ack','capabilities':['messages','memory.analyze']}))
        await connections.put(ws);await ws.wait_closed()
    async with websockets.serve(ws_handler,'127.0.0.1',0,max_size=1500000) as server:
      wp=server.sockets[0].getsockname()[1]
      with tempfile.TemporaryDirectory() as d:
        cmd=[str(binary),'--server',f'ws://127.0.0.1:{wp}/api/v1/agent/ws','--device','TE_ST_Rust','--token','local-test-token','--db',str(Path(d)/'state.sqlite'),'--endpoint',f'http://127.0.0.1:{hp}/v1/chat/completions','--model','fake-chat','--vision-model','fake-vision']
        started=time.perf_counter();proc=await asyncio.create_subprocess_exec(*cmd,stderr=asyncio.subprocess.PIPE);ws=await asyncio.wait_for(connections.get(),10);startup=time.perf_counter()-started
        metrics={'startup_to_hello_ack_ms':startup*1000,'idle_rss_bytes':psutil.Process(proc.pid).memory_info().rss}
        checks=[]
        async def send(frame): await ws.send(json.dumps(frame,ensure_ascii=False))
        async def next_frame(kind=None):
            while True:
                value=json.loads(await asyncio.wait_for(ws.recv(),10))
                if value['type']=='ping':await send({'version':1,'type':'pong'});continue
                if value['type']=='capabilities.ack':continue
                if kind is None or value['type']==kind:return value
                raise AssertionError((kind,value))
        def chat(mid,text,conv='中文 /+'):return {'version':1,'type':'message.send','message_id':mid,'conversation_id':conv,'content':text}
        async def ack(reply):await send({'version':1,'type':'message.ack','message_id':reply['message_id'],'status':'received'})
        try:
            assert seen_auth==['Bearer local-test-token'];checks.append('authenticated hello and minimal capabilities')
            await send(chat('m1','hello'));assert (await next_frame('message.ack'))['message_id']=='m1';r=await next_frame('message.reply');assert r['reply_to']=='m1' and r['conversation_id']=='中文 /+' and r['content']=='答:hello';await ack(r);checks.append('exact unicode conversation and reply correlation')
            import hashlib,urllib.parse
            identity=json.dumps(['orialis:'+urllib.parse.quote('中文 /+',safe=''),'m1','答:hello',None],ensure_ascii=False,sort_keys=True)
            assert r['message_id']=='final_'+hashlib.sha256(identity.encode()).hexdigest()[:24];checks.append('byte-identical Python deterministic final ID')
            n=len(requests);await send(chat('m1','hello'));await next_frame('message.ack');duplicate=await next_frame('message.reply');assert duplicate==r and len(requests)==n;await ack(duplicate);checks.append('duplicate input does not repeat model inference')
            await send(chat('m1','changed'));assert (await next_frame('error'))['code']=='ID_CONFLICT';checks.append('reused ID with different content refused')
            await send(chat('slow1','slow'));await next_frame('message.ack');await send({'version':1,'type':'ping'});assert (await next_frame('pong'))['type']=='pong';checks.append('reader responds to ping while model pending')
            await send(chat('parallel','parallel','parallel-conv'));await next_frame('message.ack');parallel=await next_frame('message.reply');assert parallel['reply_to']=='parallel';await ack(parallel);checks.append('different conversations run concurrently')
            await send(chat('busy','do not reorder'));await next_frame('message.ack');release.set();first=await next_frame('message.reply');second=await next_frame('message.reply');assert first['reply_to']=='slow1' and second['reply_to']=='busy';await ack(first);await ack(second);checks.append('same-conversation overlap queued and completed in FIFO order')
            await send(chat('m2','second'));await next_frame('message.ack');await ack(await next_frame('message.reply'));assert sum(x['role']=='user' for x in requests[-1]['messages'])==4;checks.append('same-conversation history retained')
            await send(chat('remember1','remember','memory-chat'));await next_frame('message.ack');await ack(await next_frame('message.reply'));assert any(m['role']=='tool' for m in requests[-1]['messages']);checks.append('memory tool loop persists preference')
            await send(chat('new1','new','brand-new'));await next_frame('message.ack');await ack(await next_frame('message.reply'));assert '喜欢中文回答' in requests[-1]['messages'][0]['content'];checks.append('new conversation loads long-term preference')
            await send({'version':1,'type':'memory.analyze','request_id':'screen1','content':'截图证据','image_base64':'/9j/AAH/2Q==','source_urls':['https://bilibili.com/video/BV1234567890?p=2&sign=a%2Fb']});mem=await next_frame('memory.result');assert mem['request_id']=='screen1' and mem['category']=='ai' and mem['content'].startswith('# ');assert mem['video_status']=='unavailable' and 'video_summary' not in mem and mem['source_url'].endswith('?p=2&sign=a%2Fb');assert requests[-1]['model']=='fake-vision' and len(requests[-1]['messages'])==2;checks.append('historyless screenshot analysis, exact URL, video limitation')
            await send({'version':1,'type':'memory.analyze','request_id':'invalid-screen','content':'x','image_base64':'bad'});bad=await next_frame('memory.result');assert bad['request_id']=='invalid-screen' and 'error' in bad;checks.append('invalid memory evidence produces correlated error')
            await send(chat('attached','file'));await next_frame('message.ack');await ack(await next_frame('message.reply'))
            f=chat('attach2','read file');f['attachments']=[{'id':'x','name':'x.pdf','mime_type':'application/pdf','download_url':'https://example.com/x'}];await send(f);await next_frame('message.ack');assert (await next_frame('error'))['code']=='UNSUPPORTED_ATTACHMENTS';checks.append('unsupported attachment cleanly refused')
            await send({'version':True,'type':'ping'});assert (await next_frame('error'))['code']=='INVALID_MESSAGE';checks.append('malformed frame rejected without disconnect')
            await send(chat('replay','persist','replay-conv'));await next_frame('message.ack');saved=await next_frame('message.reply');calls=len(requests)
            await ws.close();ws=await asyncio.wait_for(connections.get(),10)
            replay=None
            for _ in range(5):
                f=await next_frame()
                if f.get('message_id')==saved['message_id']:replay=f;break
            assert replay==saved and len(requests)==calls;await ack(replay);checks.append('reconnect resends unacknowledged final without inference')
            await asyncio.sleep(.1);proc.terminate();await proc.wait();proc=await asyncio.create_subprocess_exec(*cmd,stderr=asyncio.subprocess.PIPE);ws=await asyncio.wait_for(connections.get(),10)
            # Known refused attachment error may replay because it has no ackable message_id.
            await send(chat('m1','hello'))
            got=None
            for _ in range(8):
                f=await next_frame()
                if f.get('message_id')==r['message_id']:got=f;break
            assert got==r and len(requests)==calls;await ack(got);checks.append('dedup and prior final survive process restart')
            import sqlite3
            db=sqlite3.connect(Path(d)/'state.sqlite');assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]==5;checks.append('screen memory creates no chat session')
            await send(chat('crash-id','crash','crash-conv'));await next_frame('message.ack')
            while requests[-1]['messages'][-1].get('content')!='crash':await asyncio.sleep(.01)
            calls=len(requests);proc.kill();await proc.wait();proc=await asyncio.create_subprocess_exec(*cmd,stderr=asyncio.subprocess.PIPE);ws=await asyncio.wait_for(connections.get(),10);await send(chat('crash-id','crash','crash-conv'));await next_frame('message.ack');assert (await next_frame('error'))['code']=='INTERRUPTED_UNCERTAIN' and len(requests)==calls;checks.append('crash-uncertain work not silently executed twice');crash_release.set()
            metrics['post_workload_rss_bytes']=psutil.Process(proc.pid).memory_info().rss
        finally:
            if proc.returncode is None:proc.terminate();await proc.wait()
            await ws.close()
        print(json.dumps({'checks_passed':len(checks),'checks':checks,'metrics':metrics,'provider_calls':len(requests),'scope':'Local fake Orialis websocket and deterministic HTTP model only; no live inference or production deployment.'},ensure_ascii=False,indent=2))
    await runner.cleanup()
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=Path(__file__).parents[1]/'target/release/orialis_agent');a=p.parse_args();asyncio.run(main(a.binary.resolve()))
