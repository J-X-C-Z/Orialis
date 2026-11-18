#!/usr/bin/env python3
"""Actual temporary original Server/main/mobile parent-resume integration.

Only the HTTP model is synthetic. No --mock, production accounts or paid calls.
Pass already-built binaries explicitly. No build is performed; timing is opt-in.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

from aiohttp import web, ClientSession, WSMsgType
import websockets
from e2e_local_main import TOKEN, api
from e2e_workspace import port


async def main(args):
    checks, calls, events, errors = [], [], [], []
    assert 0 <= args.benchmark_iterations <= 100
    assert 0 <= args.idle_seconds <= 60
    if args.idle_seconds:
        args.idle_seconds = max(5, args.idle_seconds)
    resume_times, delivery_times = {}, {}
    benchmark = idle_watchdog = None
    child_ready, child_release, resume_ready, resume_release = {}, {}, {}, {}
    handles, resume_payloads = {}, {}
    user_ready, user_release = asyncio.Event(), asyncio.Event()
    blocked = {'stop', 'reset', 'incomplete', 'sendrevoked', 'interleave', 'recovery'}
    collector = agent = None

    def event(mapping, label):
        return mapping.setdefault(label, asyncio.Event())

    async def eventually(check, timeout=15):
        start = time.monotonic()
        while time.monotonic() - start < timeout:
            assert not errors, errors
            value = await check()
            if value:
                return value
            await asyncio.sleep(.025)
        raise AssertionError('timed out waiting for ' + check.__name__)

    with tempfile.TemporaryDirectory(prefix='orialis-parent-main-') as tmp:
        root = Path(tmp)
        binary = root / 'agent'
        shutil.copy2(args.binary, binary)
        artifacts = root/'artifacts'
        artifacts.mkdir()
        artifact_bytes = b'Actual parent continuation artifact bytes.\nUTF-8: \xe4\xb8\xad\xe6\x96\x87\n'
        attachment_labels = {'fileonly', 'filetext', 'crashframe', 'crashack', 'devicechanged'}
        interleaved_attachment_labels = {'fileonly', 'filetext'}
        for label in attachment_labels:
            (artifacts/(label+'.txt')).write_bytes(artifact_bytes)

        def core_content(label):
            text = 'FINAL_SYNTHESIZED_' + label + '\nExact final 中文.'
            if label == 'fileonly':
                return 'MEDIA:'+str(artifacts/(label+'.txt'))
            if label in attachment_labels:
                return text+'\nMEDIA:'+str(artifacts/(label+'.txt'))
            return text

        def visible_content(label):
            return '' if label == 'fileonly' else 'FINAL_SYNTHESIZED_' + label + '\nExact final 中文.'


        def tool(name, arguments, ident):
            return {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': ident, 'type': 'function', 'function': {
                    'name': name, 'arguments': json.dumps(arguments)}}]}

        async def model(request):
            payload = await request.json()
            calls.append(payload)
            messages = payload['messages']
            try:
                child = messages[0]['content'].startswith('You are an isolated delegated assistant.')
                user = next(m['content'] for m in reversed(messages) if m['role'] == 'user')
                label = re.search(r'PCCASE:([a-z]+):END', user).group(1)
                seeds = [i for i, m in enumerate(messages) if any(
                    c['function']['name'] == 'delegate_task_completion' for c in m.get('tool_calls', []))]
                if child:
                    assert 'PRIVATE_PARENT' not in json.dumps(messages)
                    event(child_ready, label).set()
                    await event(child_release, label).wait()
                    response = {'role': 'assistant', 'content': 'RAW_CHILD_' + label}
                elif seeds and seeds[-1] > max(i for i, m in enumerate(messages) if m['role'] == 'user'):
                    i = seeds[-1]
                    assert messages[i]['role'] == 'assistant'
                    assert messages[i+1]['role'] == 'tool'
                    assert messages[i+1]['tool_call_id'] == messages[i]['tool_calls'][0]['id']
                    assert 'RAW_CHILD_' + label in messages[i+1]['content']
                    assert any(m.get('content') == 'PARENT_RETURNED_' + label for m in messages[:i])
                    assert len([m for m in messages if m['role'] == 'user']) == (2 if label in interleaved_attachment_labels else 1)
                    assert not any('RAW_CHILD_' in str(m.get('content', '')) for m in messages if m['role'] in ('system', 'user'))
                    resume_times.setdefault(label, time.monotonic_ns())
                    resume_payloads.setdefault(label, []).append(payload)
                    event(resume_ready, label).set()
                    if label in blocked or label.startswith('parallel'):
                        await event(resume_release, label).wait()
                    receipts = [m for m in messages[i+2:] if m['role'] == 'tool']
                    if label == 'depth' and not receipts and any(t['function']['name'] == 'delegate_task' for t in payload['tools']):
                        response = tool('delegate_task', {'background': True, 'tasks': [{'goal': 'PCCASE:depth:END'}]}, 'nested-dispatch')
                    elif label == 'done' and not receipts:
                        assert any(t['function']['name'] == 'create_task' for t in payload['tools'])
                        response = tool('create_task', {'title': 'CONTINUATION_SAFE_TASK'}, 'followup-task')
                    else:
                        if label == 'done':
                            assert 'CONTINUATION_SAFE_TASK' in receipts[-1]['content'], receipts
                        response = {'role': 'assistant', 'content': core_content(label)}
                elif user.endswith('INTERLEAVED'):
                    if label == 'waitowner':
                        user_ready.set()
                        await user_release.wait()
                    response = {'role': 'assistant', 'content': 'INTERLEAVED_RETURNED'}
                else:
                    at = max(i for i, m in enumerate(messages) if m['role'] == 'user')
                    receipts = [m for m in messages[at:] if m['role'] == 'tool']
                    if not receipts:
                        response = tool('delegate_task', {'background': True, 'tasks': [{'goal': 'PCCASE:' + label + ':END'}]}, 'dispatch-' + label)
                    else:
                        handles[label] = json.loads(receipts[-1]['content'])
                        assert handles[label]['mode'] == 'background'
                        response = {'role': 'assistant', 'content': 'PARENT_RETURNED_' + label}
            except Exception as exc:
                errors.append(repr(exc))
                raise
            finish = 'tool_calls' if response.get('tool_calls') else 'stop'
            if not payload.get('stream'):
                return web.json_response({'choices': [{'message': response, 'finish_reason': finish}]})
            stream = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await stream.prepare(request)
            delta = dict(response)
            if 'tool_calls' in delta:
                delta['tool_calls'] = [dict(t, index=i) for i, t in enumerate(delta['tool_calls'])]
            for value in [{'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                          {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]}]:
                await stream.write(('data: ' + json.dumps(value) + '\n\n').encode())
            await stream.write(b'data: [DONE]\n\n')
            await stream.write_eof()
            return stream

        app = web.Application()
        app.router.add_post('/v1/chat/completions', model)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        model_port = site._server.sockets[0].getsockname()[1]
        base = 'http://127.0.0.1:' + str(port())
        relay_port = port()
        relay_base = 'http://127.0.0.1:'+str(relay_port)
        env = os.environ.copy()
        env.update(ORIALIS_ENV='development', ORIALIS_HOST='127.0.0.1',
                   ORIALIS_PORT=base.rsplit(':', 1)[1], ORIALIS_PUBLIC_URL=relay_base,
                   ORIALIS_DEV_DEVICE_AUTH='false', ORIALIS_DATABASE_URL=f'sqlite://{root}/server.sqlite?mode=rwc',
                   ORIALIS_UPLOAD_DIR=str(root/'uploads'), ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,
                   ORIALIS_AGENT_USER_ID='full-owner')
        sl, al = (root/'server.log').open('w+'), (root/'agent.log').open('w+')
        server = subprocess.Popen([str(args.server)], env=env, stdout=sl, stderr=subprocess.STDOUT)
        # Transparent local relay is a transport fault fixture, not a Server edit.
        # HTTP preserves owner/upload operations; WS gates only specified reply IDs.
        relay_session = ClientSession(auto_decompress=False)
        fault_targets, fault_seen, fault_release, wire_frames = {}, {}, {}, []
        upload_requests = {}
        strip_followups = False

        async def relay(request):
            if request.path == '/api/v1/agent/ws':
                downstream = web.WebSocketResponse()
                await downstream.prepare(request)
                async with relay_session.ws_connect(base.replace('http', 'ws')+request.path_qs,
                        headers={'Authorization': 'Bearer '+TOKEN}) as upstream:
                    async def forward(source, destination, direction):
                        async for message in source:
                            if message.type != WSMsgType.TEXT:
                                if message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                                    break
                                continue
                            frame = json.loads(message.data)
                            if direction == 'server_to_agent' and strip_followups and isinstance(frame.get('capabilities'), list):
                                frame['capabilities'] = [c for c in frame['capabilities'] if c != 'reply_followups']
                            ident = frame.get('message_id')
                            wire_frames.append({'direction': direction, 'frame': frame})
                            target = fault_targets.get(ident)
                            if target and ((target == 'before_send' and direction == 'agent_to_server' and frame.get('type') == 'message.reply')
                                           or (target == 'before_ack' and direction == 'server_to_agent' and frame.get('type') == 'message.ack')):
                                event(fault_seen, ident).set()
                                await event(fault_release, ident).wait()
                            await destination.send_str(json.dumps(frame))
                    tasks = [asyncio.create_task(forward(downstream, upstream, 'agent_to_server')),
                             asyncio.create_task(forward(upstream, downstream, 'server_to_agent'))]
                    _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                    for task in pending:
                        task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                await downstream.close()
                return downstream
            headers = {k: v for k, v in request.headers.items()
                       if k.lower() not in ('host', 'connection', 'transfer-encoding', 'content-length')}
            if request.method == 'POST' and request.path.endswith('/attachments'):
                upload_requests[request.path] = upload_requests.get(request.path, 0)+1
            body = await request.read()
            async with relay_session.request(request.method, base+request.path_qs, data=body,
                    headers=headers, allow_redirects=False) as response:
                data = await response.read()
                response_headers = {k: v for k, v in response.headers.items()
                                    if k.lower() not in ('connection', 'transfer-encoding', 'content-length')}
                return web.Response(status=response.status, body=data, headers=response_headers)

        relay_app = web.Application(client_max_size=4*1024*1024)
        relay_app.router.add_route('*', '/{path:.*}', relay)
        relay_runner = web.AppRunner(relay_app)
        await relay_runner.setup()
        relay_site = web.TCPSite(relay_runner, '127.0.0.1', relay_port)
        await relay_site.start()
        relay_base = 'http://127.0.0.1:'+str(relay_site._server.sockets[0].getsockname()[1])
        command = [str(binary), '--server', relay_base.replace('http', 'ws')+'/api/v1/agent/ws',
                   '--device', 'TE_ST_ParentResume', '--token', TOKEN, '--db', str(root/'agent.sqlite'),
                   '--endpoint', f'http://127.0.0.1:{model_port}/v1/chat/completions', '--verify-owner',
                   '--expected-owner', 'full-owner', '--session-context', '--delegation',
                   '--delegation-background', '--domain-tools', '--stream-events', '--inbound-deliveries',
                   '--attachments', '--output-files', '--artifact-root', str(artifacts)]

        async def start(enabled=True):
            process = subprocess.Popen(command + (['--delegation-parent-resume'] if enabled else []), env=env, stdout=al, stderr=subprocess.STDOUT)
            async def online():
                assert process.poll() is None, 'Agent exited'
                devices = await asyncio.to_thread(api, base, 'GET', '/api/v1/agent/devices')
                return any(v['deviceId'] == 'TE_ST_ParentResume' and v['online'] for v in devices['devices'])
            await eventually(online)
            return process

        async def stop(kill=False):
            nonlocal agent
            (agent.kill if kill else agent.terminate)()
            code = await asyncio.to_thread(agent.wait, 5)
            if not kill:
                assert code == 0, code
            agent = None
            await asyncio.sleep(.2)

        async def send(label, mid, text):
            return await asyncio.to_thread(api, base, 'POST', f'/api/v1/conversations/pc-{label}/messages', {'id': mid, 'content': text})

        async def finals(label, count=1):
            async def found():
                page = await asyncio.to_thread(api, base, 'GET', f'/api/v1/conversations/pc-{label}/messages?limit=500')
                rows = [m for m in page['items'] if m['role'] == 'assistant' and m['id'].startswith('final_')]
                return rows if len(rows) >= count else None
            return await eventually(found)

        async def begin(label):
            await asyncio.to_thread(api, base, 'POST', '/api/v1/conversations', {'id': 'pc-'+label, 'title': 'Synthetic parent resume'})
            await asyncio.to_thread(api, base, 'PUT', f'/api/v1/conversations/pc-{label}/agent-device', {'deviceId': 'TE_ST_ParentResume'})
            await send(label, 'input-'+label, 'PCCASE:'+label+':END PRIVATE_PARENT')
            rows = await finals(label)
            assert rows[-1]['content'] == 'PARENT_RETURNED_'+label, rows
            await asyncio.wait_for(event(child_ready, label).wait(), 5)
            assert not event(child_release, label).is_set()

        def source_id(label):
            with sqlite3.connect(root/'agent.delegation.sqlite') as db:
                return db.execute('SELECT notification_id FROM delegation_background WHERE batch=?', (handles[label]['delegation_id'],)).fetchone()[0]

        def queue_row(label):
            with sqlite3.connect(root/'agent.parent-continuation.sqlite') as db:
                db.row_factory = sqlite3.Row
                row = db.execute('SELECT * FROM parent_continuations WHERE id=?', (source_id(label),)).fetchone()
                return dict(row) if row else None

        def notifications(label):
            ident = 'parent-final:' + source_id(label)
            return [e for e in events if e.get('payload', {}).get('kind') == 'delivery.notification' and e['payload'].get('messageId') == ident]

        def reply_id(label):
            # VerifiedOwner::scope binds HTTP origin, device and authenticated user.
            # This fixture uses an already canonical loopback gateway URL.
            device = 'TE_ST_ParentResume'
            owner_scope = hashlib.sha256((relay_base+'\0'+device+'\0full-owner').encode()).hexdigest()
            canonical_ws_url = relay_base.replace('http', 'ws')+'/api/v1/agent/ws'
            identity_json = json.dumps(['parent-reply-v1', canonical_ws_url, device, owner_scope],
                                       separators=(',', ':'), ensure_ascii=False)
            namespace = hashlib.sha256(identity_json.encode()).hexdigest()[:32]
            ident = 'parent-reply:'+namespace+':'+source_id(label)
            assert len(ident.encode()) <= 160
            return ident

        def replies(label):
            ident = reply_id(label)
            return [e for e in events if e.get('type') == 'message' and e.get('payload', {}).get('id') == ident]

        def stored_reply(label, ident=None):
            with sqlite3.connect(root/'server.sqlite') as db:
                db.row_factory = sqlite3.Row
                row = db.execute('SELECT * FROM messages WHERE id=?', (ident or reply_id(label),)).fetchone()
                return dict(row) if row else None

        def reply_outbox(label):
            with sqlite3.connect(root/'agent.delivery.sqlite') as db:
                db.row_factory = sqlite3.Row
                row = db.execute('SELECT * FROM continuation_replies WHERE message_id=?', (reply_id(label),)).fetchone()
                return dict(row) if row else None

        async def acknowledged(label):
            async def found():
                row = reply_outbox(label)
                if row and row['state'] == 'delivered':
                    assert stored_reply(label), 'delivered receipt preceded Server persistence'
                    return row
            return await eventually(found)

        async def delivered(label):
            async def found():
                return replies(label) if stored_reply(label) else None
            rows = await eventually(found)
            receipt = await acknowledged(label)
            request = json.loads(receipt['request'])
            assert request['frame']['reply_to'] == 'input-'+label
            assert request['source']['root_input_id'] == 'input-'+label
            assert request['frame']['message_id'] == reply_id(label)
            row = queue_row(label)
            final = json.loads(row['final_json'])
            assert final['content'] == core_content(label), final
            payload = rows[-1]['payload']
            persisted = stored_reply(label)
            for value in (payload, persisted):
                assert value['content'] == visible_content(label), value
                assert value['role'] == 'assistant'
            assert payload['replyToMessageId'] == 'input-'+label, payload
            assert persisted['reply_to_message_id'] == 'input-'+label, persisted
            assert payload['conversationId'] == 'pc-'+label
            assert 'RAW_CHILD_' not in json.dumps(payload)
            assert not notifications(label), 'chat followup incorrectly fell back to notification'
            assert not any(e.get('payload', {}).get('messageId') == source_id(label) for e in events)
            with sqlite3.connect(root/'server.sqlite') as db:
                users = db.execute("SELECT id FROM messages WHERE conversation_id=? AND role='user'", ('pc-'+label,)).fetchall()
                expected_users = 2 if label in interleaved_attachment_labels or label == 'interleave' else 1
                assert len(users) == expected_users, users
            attachments = payload.get('attachments', [])
            assert attachments == json.loads(persisted['attachments_json'])
            if label in attachment_labels:
                assert len(attachments) == 1, payload
                assert upload_requests.get('/api/v1/conversations/pc-'+label+'/attachments') == 1
                attachment = attachments[0]
                url = attachment.get('downloadUrl') or attachment.get('download_url')
                url = base+url if url.startswith('/') else url
                def download():
                    request = urllib.request.Request(url, headers={'Authorization': 'Bearer '+TOKEN})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        return response.read()
                assert await asyncio.to_thread(download) == artifact_bytes
                with sqlite3.connect(root/'server.sqlite') as db:
                    assert db.execute('SELECT count(*) FROM attachments WHERE conversation_id=?', ('pc-'+label,)).fetchone()[0] == 1
                    assert db.execute('SELECT count(*) FROM attachment_uploads WHERE conversation_id=?', ('pc-'+label,)).fetchone()[0] == 1
                async def output_acknowledged():
                    with sqlite3.connect(root/'agent.output.sqlite') as db:
                        files = db.execute('SELECT state,delivered_at FROM output_files WHERE conversation_id=?', ('pc-'+label,)).fetchall()
                        mapped = db.execute('SELECT acked_at FROM output_final_messages WHERE id=?', (reply_id(label),)).fetchone()
                        return len(files) == 1 and files[0][0] == 'uploaded' and files[0][1] is not None and mapped and mapped[0] is not None
                await eventually(output_acknowledged)
                with sqlite3.connect(root/'agent.sqlite') as db:
                    saved = db.execute('SELECT final_assistant FROM context_turns WHERE input_id=?', (row['input'],)).fetchone()[0]
                    assert json.loads(saved)['content'] == core_content(label)
            else:
                assert attachments == []
            return row

        async def drain(mobile):
            async for raw in mobile:
                received = time.monotonic_ns()
                envelope = json.loads(raw)
                events.append(envelope)
                payload = envelope.get('payload', {})
                if envelope.get('type') == 'message':
                    delivery_times.setdefault(payload.get('id'), received)
                elif payload.get('kind') == 'delivery.notification':
                    delivery_times.setdefault(payload.get('messageId'), received)

        def own_process():
            assert agent is not None and agent.poll() is None
            fields = Path(f'/proc/{agent.pid}/stat').read_text().rsplit(')', 1)[1].split()
            status = Path(f'/proc/{agent.pid}/status').read_text()
            memory = {line.split(':', 1)[0]: int(line.split()[1])*1024
                      for line in status.splitlines() if line.startswith(('VmRSS:', 'VmHWM:'))}
            return {'pid': agent.pid,
                    'cpu_seconds': (int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                    'memory_bytes': memory, 'observed_monotonic_ns': time.monotonic_ns()}

        def owner(label, value):
            with sqlite3.connect(root/'server.sqlite') as db:
                db.execute('UPDATE conversations SET user_id=? WHERE id=?', (value, 'pc-'+label))

        try:
            for _ in range(400):
                try:
                    await asyncio.to_thread(api, base, 'GET', '/api/v1/health')
                    break
                except OSError:
                    await asyncio.sleep(.025)
            with sqlite3.connect(root/'server.sqlite') as db:
                for ident in ['full-owner', 'other-owner']:
                    db.execute('INSERT INTO users(id,username,password_hash) VALUES(?,?,?)', (ident, ident, 'synthetic-no-login'))
                db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('full-session','full-owner',?,'2099-01-01T00:00:00Z')", (hashlib.sha256(b'synthetic-mobile-session').hexdigest(),))
            agent = await start(False)
            async with websockets.connect(base.replace('http', 'ws')+'/api/v1/ws', additional_headers={'Authorization': 'Session synthetic-mobile-session'}) as mobile:
                await mobile.send(json.dumps({'version': 1, 'type': 'hello', 'payload': {}}))
                assert json.loads(await mobile.recv())['type'] == 'hello.ack'
                collector = asyncio.create_task(drain(mobile))
                await begin('disabled')
                event(child_release, 'disabled').set()
                async def legacy_delivered():
                    return any(e.get('payload', {}).get('messageId') == source_id('disabled') for e in events)
                await eventually(legacy_delivered)
                assert 'disabled' not in resume_payloads
                checks.append('parent resume is opt-in; disabled mode retains legacy notification without model wake')
                await stop()
                agent = await start()
                await begin('done')
                event(child_release, 'done').set()
                await delivered('done')
                with sqlite3.connect(root/'server.sqlite') as db:
                    assert db.execute("SELECT count(*) FROM tasks WHERE title='CONTINUATION_SAFE_TASK'").fetchone()[0] == 1
                checks.append('parent returns before child; completion wakes model with history and assistant/tool seed, then creates one real task and sends exact Core final only')
                before = len(calls)
                await send('done', 'input-done', 'PCCASE:done:END PRIVATE_PARENT')
                await asyncio.sleep(.3)
                await stop()
                agent = await start()
                await asyncio.sleep(1.3)
                assert len(calls) == before
                assert len(replies('done')) == 1
                with sqlite3.connect(root/'server.sqlite') as db:
                    assert db.execute("SELECT count(*) FROM tasks WHERE title='CONTINUATION_SAFE_TASK'").fetchone()[0] == 1
                checks.append('duplicate inbound ID and restart do not repeat provider, domain mutation or acknowledged final')

                for label in sorted(interleaved_attachment_labels):
                    await begin(label)
                    # Finish a newer, real user turn before the child finishes.
                    await send(label, 'newer-'+label, 'PCCASE:'+label+':END INTERLEAVED')
                    rows = await finals(label, 2)
                    assert any(m['content'] == 'INTERLEAVED_RETURNED' for m in rows)
                    event(child_release, label).set()
                    await delivered(label)
                    before = len(calls)
                    await send(label, 'input-'+label, 'PCCASE:'+label+':END PRIVATE_PARENT')
                    await stop()
                    agent = await start()
                    await asyncio.sleep(1.3)
                    assert len(calls) == before and len(replies(label)) == 1
                    await delivered(label)
                checks.append('attachment-only and text-plus-attachment followups persist once, download exact bytes, keep Core final intact, and reply to original root after newer user completes; restart repeats no provider or upload')

                for label, gate in [('crashframe', 'before_send'), ('crashack', 'before_ack')]:
                    await begin(label)
                    ident = reply_id(label)
                    fault_targets[ident] = gate
                    event(child_release, label).set()
                    await asyncio.wait_for(event(fault_seen, ident).wait(), 15)
                    outbox_before = reply_outbox(label)
                    assert outbox_before['state'] == 'pending' and outbox_before['attempts'] > 0
                    frame_before = json.loads(outbox_before['request'])['frame']
                    assert frame_before['attachments']
                    with sqlite3.connect(root/'agent.output.sqlite') as db:
                        assert db.execute('SELECT state,delivered_at FROM output_files WHERE conversation_id=?', ('pc-'+label,)).fetchall() == [('uploaded', None)]
                        assert db.execute('SELECT acked_at FROM output_final_messages WHERE id=?', (ident,)).fetchone() == (None,)
                    assert bool(stored_reply(label)) == (gate == 'before_ack')
                    with sqlite3.connect(root/'server.sqlite') as db:
                        assert db.execute('SELECT count(*) FROM attachment_uploads WHERE conversation_id=?', ('pc-'+label,)).fetchone()[0] == 1
                    before = len(calls)
                    await stop(True)
                    del fault_targets[ident]
                    event(fault_release, ident).set()
                    agent = await start()
                    await delivered(label)
                    assert len(calls) == before
                    assert json.loads(reply_outbox(label)['request'])['frame'] == frame_before
                    with sqlite3.connect(root/'server.sqlite') as db:
                        assert db.execute('SELECT count(*) FROM messages WHERE id=?', (ident,)).fetchone()[0] == 1
                    sent = [w['frame'] for w in wire_frames if w['direction'] == 'agent_to_server' and w['frame'].get('type') == 'message.reply' and w['frame'].get('message_id') == ident]
                    assert len(sent) >= 2 and all(frame == frame_before for frame in sent)
                    assert len(replies(label)) == 1
                checks.append('SIGKILL after immutable attachment reply frame and after Server commit before ACK replays identical frame once without duplicate message, model, tool or upload; delivered set only after message ACK')

                await begin('devicechanged')
                ident = reply_id('devicechanged')
                fault_targets[ident] = 'before_send'
                event(child_release, 'devicechanged').set()
                await asyncio.wait_for(event(fault_seen, ident).wait(), 15)
                with sqlite3.connect(root/'server.sqlite') as db:
                    db.execute("UPDATE conversations SET agent_device_id='OTHER_SYNTHETIC_DEVICE' WHERE id='pc-devicechanged'")
                del fault_targets[ident]
                event(fault_release, ident).set()
                async def device_rejected():
                    return any(w['direction'] == 'server_to_agent' and w['frame'].get('code') == 'REPLY_REJECTED' and w['frame'].get('reply_to') == ident for w in wire_frames)
                await eventually(device_rejected)
                assert not stored_reply('devicechanged') and not replies('devicechanged') and not notifications('devicechanged')
                assert reply_outbox('devicechanged')['state'] != 'delivered'
                checks.append('Server atomically rejects old-device attachment reply after device binding changes; no persisted row, delivered flag or notification fallback')

                await stop()
                strip_followups = True
                agent = await start()
                await begin('nocap')
                event(child_release, 'nocap').set()
                async def nocap_final():
                    row = queue_row('nocap')
                    return row and row['final_json'] is not None
                await eventually(nocap_final)
                await asyncio.sleep(1.3)
                assert not stored_reply('nocap') and not replies('nocap') and not notifications('nocap')
                before = len(calls)
                await stop()
                strip_followups = False
                agent = await start()
                await delivered('nocap')
                assert len(calls) == before
                checks.append('missing negotiated reply_followups retains chat final without silent notification fallback; capability restoration delivers without model replay')

                for label, control in [('stop', '/stop'), ('reset', '/new')]:
                    await begin(label)
                    event(child_release, label).set()
                    await asyncio.wait_for(event(resume_ready, label).wait(), 10)
                    await send(label, 'control-'+label, control)
                    await finals(label, 2)
                    event(resume_release, label).set()
                    await asyncio.sleep(1.3)
                    assert not replies(label) and not notifications(label)
                    checks.append(control+' fences pending continuation after original ActiveChat is gone')

                await begin('incomplete')
                event(child_release, 'incomplete').set()
                await asyncio.wait_for(event(resume_ready, 'incomplete').wait(), 10)
                before = len(calls)
                await stop(True)
                event(resume_release, 'incomplete').set()
                agent = await start()
                async def uncertain():
                    row = queue_row('incomplete')
                    return row and row['state'] in ('uncertain', 'enqueued') and row['final_json'] is None
                await eventually(uncertain)
                async def diagnostic_delivered():
                    return replies('incomplete')
                diagnostic = (await eventually(diagnostic_delivered))[-1]['payload']['content']
                assert len(calls) == before
                assert 'execution interrupted; Core input cancelled; no automatic model or tool replay' in diagnostic
                assert 'RAW_CHILD_' not in diagnostic and 'FINAL_SYNTHESIZED_' not in diagnostic
                assert queue_row('incomplete')['final_json'] is None
                assert stored_reply('incomplete')['reply_to_message_id'] == 'input-incomplete'
                await acknowledged('incomplete')
                checks.append('hard kill of admitted incomplete continuation emits only immutable uncertainty diagnostic and never replays model/tools')

                # Hold only the queue write lock: Core must still commit its final.
                # Kill in the real Core-committed / queue-not-copied window.
                await begin('recovery')
                event(child_release, 'recovery').set()
                await asyncio.wait_for(event(resume_ready, 'recovery').wait(), 10)
                row = queue_row('recovery')
                lock = sqlite3.connect(root/'agent.parent-continuation.sqlite')
                lock.execute('BEGIN IMMEDIATE')
                try:
                    event(resume_release, 'recovery').set()
                    async def core_committed():
                        with sqlite3.connect(root/'agent.sqlite') as db:
                            value = db.execute('SELECT final_assistant FROM context_turns WHERE input_id=? AND state=\'finalized\'', (row['input'],)).fetchone()
                            return value and value[0]
                    await eventually(core_committed, 4)
                    assert queue_row('recovery')['final_json'] is None
                    before = len(calls)
                    await stop(True)
                finally:
                    lock.rollback()
                    lock.close()
                agent = await start()
                await delivered('recovery')
                assert len(calls) == before
                checks.append('real hardkill after Core commit but before queue copy recovers exact final without model replay')

                await begin('interleave')
                event(child_release, 'interleave').set()
                await asyncio.wait_for(event(resume_ready, 'interleave').wait(), 10)
                await send('interleave', 'interleaved-user', 'PCCASE:interleave:END INTERLEAVED')
                await asyncio.sleep(.3)
                assert not any(p['messages'][-1].get('content') == 'PCCASE:interleave:END INTERLEAVED' for p in calls)
                event(resume_release, 'interleave').set()
                rows = await finals('interleave', 2)
                assert any(m['content'] == 'INTERLEAVED_RETURNED' for m in rows)
                await delivered('interleave')
                checks.append('interleaving user turn waits for same-route parent continuation and then executes')

                parallel = ['parallel'+c for c in 'abcdef']
                for label in parallel:
                    await begin(label)
                for label in parallel:
                    event(child_release, label).set()
                async def four_started():
                    return sum(event(resume_ready, label).is_set() for label in parallel) == 4
                await eventually(four_started)
                await asyncio.sleep(.3)
                assert sum(event(resume_ready, label).is_set() for label in parallel) == 4
                for label in parallel:
                    event(resume_release, label).set()
                for label in parallel:
                    await delivered(label)
                checks.append('six ready routes admit at most four running continuations; queued remainder drains')

                await begin('depth')
                event(child_release, 'depth').set()
                await delivered('depth')
                async def depth_finished():
                    with sqlite3.connect(root/'agent.parent-continuation.sqlite') as db:
                        rows = db.execute("SELECT depth,state FROM parent_continuations WHERE conversation='pc-depth' ORDER BY depth").fetchall()
                        return rows if len(rows) == 2 and all(state == 'enqueued' for _, state in rows) else None
                lineage = await eventually(depth_finished)
                assert [depth for depth, _ in lineage] == [1, 2], lineage
                assert not any(t['function']['name'] == 'delegate_task' for t in resume_payloads['depth'][-1]['tools'])
                async def nested_persisted():
                    with sqlite3.connect(root/'server.sqlite') as db:
                        rows = db.execute("SELECT reply_to_message_id FROM messages WHERE conversation_id='pc-depth' AND id LIKE 'parent-reply:%'").fetchall()
                        return rows if len(rows) == 2 else None
                assert await eventually(nested_persisted) == [('input-depth',), ('input-depth',)]
                checks.append('nested completion reaches depth two and retains original real user anchor; delegation tool removed at boundary')

                await begin('revoked')
                owner('revoked', 'other-owner')
                event(child_release, 'revoked').set()
                await asyncio.sleep(2)
                assert 'revoked' not in resume_payloads and not replies('revoked') and not notifications('revoked')
                owner('revoked', 'full-owner')
                await stop()
                agent = await start()
                await delivered('revoked')
                checks.append('owner revoked before resume prevents provider execution; restored owner permits retained work')

                await begin('waitowner')
                await send('waitowner', 'waitowner-user', 'PCCASE:waitowner:END INTERLEAVED')
                await asyncio.wait_for(user_ready.wait(), 10)
                event(child_release, 'waitowner').set()
                async def waiting_for_route():
                    row = queue_row('waitowner')
                    return row and row['state'] == 'running'
                await eventually(waiting_for_route)
                owner('waitowner', 'other-owner')
                user_release.set()
                await asyncio.sleep(2)
                assert 'waitowner' not in resume_payloads and not replies('waitowner') and not notifications('waitowner')
                checks.append('ownership revoked while continuation waits behind real user turn is checked again after acquiring Core route')

                await begin('sendrevoked')
                event(child_release, 'sendrevoked').set()
                await asyncio.wait_for(event(resume_ready, 'sendrevoked').wait(), 10)
                owner('sendrevoked', 'other-owner')
                event(resume_release, 'sendrevoked').set()
                await asyncio.sleep(2)
                assert not replies('sendrevoked') and not notifications('sendrevoked')
                checks.append('owner revoked during parent model execution blocks final delivery')

                if args.benchmark_iterations:
                    before = own_process()
                    before_calls = len(calls)
                    samples = []
                    for index in range(args.benchmark_iterations):
                        label = 'bench'+chr(97+index//26)+chr(97+index%26)
                        await begin(label)
                        released = time.monotonic_ns()
                        event(child_release, label).set()
                        row = await delivered(label)
                        notification_id = reply_id(label)
                        received = delivery_times[notification_id]
                        samples.append({
                            'iteration': index, 'child_released_ns': released,
                            'first_continuation_provider_ns': resume_times[label],
                            'final_mobile_received_ns': received,
                            'child_release_to_parent_provider_ms': (resume_times[label]-released)/1e6,
                            'parent_provider_to_mobile_final_ms': (received-resume_times[label])/1e6,
                            'child_release_to_mobile_final_ms': (received-released)/1e6,
                            'continuation_provider_calls': len(resume_payloads[label]),
                            'notification_id': notification_id,
                            'committed_final': json.loads(row['final_json']),
                            'mobile_receipt': replies(label)[-1],
                            'continuation_message_roles': [m['role'] for m in resume_payloads[label][0]['messages']],
                        })
                    after = own_process()
                    benchmark = {'iterations': args.benchmark_iterations, 'raw_samples': samples,
                                 'agent_before': before, 'agent_after': after,
                                 'provider_calls': len(calls)-before_calls,
                                 'agent_cpu_ms_per_complete_task': (after['cpu_seconds']-before['cpu_seconds'])*1000/args.benchmark_iterations,
                                 'scope': 'Warm real Agent + original Server + transparent local transport relay + synthetic HTTP model. CPU includes parent admission, child and resumed parent; driver polling is not Agent CPU. Latency timestamps come from child release, provider handler entry and mobile websocket arrival. Memory includes correctness fixtures and is not an isolated per-phase peak. No production model quality or broad exactly-once guarantee.'}

                if args.idle_seconds:
                    async def idle_phase():
                        before = own_process()
                        count_before = len(calls)
                        child_before = sum(1 for p in calls if p['messages'][0]['content'].startswith('You are an isolated delegated assistant.'))
                        with sqlite3.connect(root/'agent.parent-continuation.sqlite') as db:
                            queue_states = dict(db.execute('SELECT state,count(*) FROM parent_continuations GROUP BY state').fetchall())
                        await asyncio.sleep(args.idle_seconds)
                        after = own_process()
                        child_after = sum(1 for p in calls if p['messages'][0]['content'].startswith('You are an isolated delegated assistant.'))
                        assert len(calls) == count_before
                        return {'requested_idle_seconds': args.idle_seconds,
                                'elapsed_seconds': (after['observed_monotonic_ns']-before['observed_monotonic_ns'])/1e9,
                                'agent_cpu_ms': (after['cpu_seconds']-before['cpu_seconds'])*1000,
                                'provider_calls_before': count_before, 'provider_calls_after': len(calls),
                                'child_calls_before': child_before, 'child_calls_after': child_after,
                                'queue_states_at_start': queue_states,
                                'agent_before': before, 'agent_after': after}
                    async def no_active_continuations():
                        with sqlite3.connect(root/'agent.parent-continuation.sqlite') as db:
                            return db.execute("SELECT count(*) FROM parent_continuations WHERE state IN ('claimed','running')").fetchone()[0] == 0
                    await eventually(no_active_continuations)
                    idle_baseline = await idle_phase()
                    labels = ['parallelidle'+c for c in 'abcd']
                    for label in labels:
                        await begin(label)
                    for label in labels:
                        event(child_release, label).set()
                    for label in labels:
                        await asyncio.wait_for(event(resume_ready, label).wait(), 15)
                    blocked_phase = await idle_phase()
                    idle_watchdog = {'baseline_zero_active': idle_baseline,
                                     'four_blocked_continuations': blocked_phase,
                                     'same_binary_same_process_same_flags': True,
                                     'scope': 'Two sequential >=5s observations of the same opt-in enabled Agent process with identical profile/background flags. Baseline has zero running continuations; second phase has four actual HTTP continuation responses blocked. Real /proc user+system ticks and RSS/HWM, not shell CPU. CPU values are absolute phase measurements, not incremental overhead; background activity, warm-state differences and tick quantization apply. Not a randomized controlled benchmark or cold-memory peak.'}
                    for label in labels:
                        event(resume_release, label).set()
                    for label in labels:
                        await delivered(label)
                assert not stored_reply('devicechanged') and not replies('devicechanged') and not notifications('devicechanged')
                await stop()
        except Exception:
            al.seek(0)
            sl.seek(0)
            print('AGENT', al.read())
            print('SERVER', sl.read()[-5000:])
            print('EVENTS', json.dumps(events[-12:], ensure_ascii=False))
            raise
        finally:
            user_release.set()
            for mapping in [child_release, resume_release]:
                for value in mapping.values():
                    value.set()
            if collector:
                collector.cancel()
                await asyncio.gather(collector, return_exceptions=True)
            if agent:
                agent.terminate()
                await asyncio.to_thread(agent.wait, 5)
            server.terminate()
            await asyncio.to_thread(server.wait, 5)
            await relay_runner.cleanup()
            await relay_session.close()
            await runner.cleanup()
        result = {'passed': len(checks), 'checks': checks, 'provider_calls': len(calls),
                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'server_sha256': hashlib.sha256(args.server.read_bytes()).hexdigest(),
                  'benchmark': benchmark, 'idle_watchdog': idle_watchdog,
                  'attachment_upload_http_counts': upload_requests,
                  'limitations': 'Synthetic provider and transparent transport-fault relay, temporary original Server/main/mobile protocol. No production, paid model, Flutter UI or performance claim. Arbitrary external side effects are not claimed exactly-once.'}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--benchmark-iterations', type=int, default=0)
    parser.add_argument('--idle-seconds', type=float, default=0)
    asyncio.run(main(parser.parse_args()))
