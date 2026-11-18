#!/usr/bin/env python3
"""Real server/mobile approval -> built main Agent -> sandboxed persistent Python.

Only synthetic local accounts, inputs, and a controlled model are used. Model
responses assert actual execute_code results, rather than mocking tool outcomes.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time

from aiohttp import web
import websockets
from e2e_local_main import api, TOKEN
from e2e_workspace import ROOT, port


async def main(args):
    checks, calls, outcomes, approvals, events = [], [], {}, [], []
    cases = {
        'seed': ('counter = 40\nprint(counter)', '40', False, 1),
        'increment': ('counter += 2\nprint(counter)', '42', True, 2),
        'isolated': ("print('counter' in globals())", 'False', False, 1),
        'probe-replay': ('print(counter)', '42', True, 3),
        'after-new': ("print('counter' in globals())", 'False', False, 1),
        'before-restart': ('restart_value = 17\nprint(restart_value)', '17', True, 2),
        'after-restart': ("print('restart_value' in globals())", 'False', False, 1),
        'bridge-read': ("import json\nfrom hermes_tools import list_tasks\nprint(json.dumps(list_tasks()))", None, True, 2),
        'slow': ("open('cell-started.txt', 'w').write('actual cell running')\nimport time\ntime.sleep(20)\nprint('SHOULD NOT COMPLETE')", None, None, None),
        'after-stop': ("print('counter' in globals())", 'False', False, 1),
    }
    with tempfile.TemporaryDirectory(prefix='orialis-python-main-') as temp:
        directory = Path(temp)
        binary = directory / 'agent'
        shutil.copy2(args.binary, binary)
        workspace = directory / 'workspace'
        workspace.mkdir()

        async def model(request):
            payload = await request.json()
            calls.append(payload)
            messages = payload['messages']
            at = max(i for i, m in enumerate(messages) if m['role'] == 'user')
            label = messages[at]['content']
            # Session context can wrap the original input in metadata.
            label = next(k for k in cases if f'PYCASE:{k}:END' in label)
            results = [m for m in messages[at:] if m['role'] == 'tool']
            if not results:
                assert any(t['function']['name'] == 'execute_code' for t in payload['tools'])
                delta = {'role': 'assistant', 'tool_calls': [{
                    'index': 0, 'id': 'python-' + label, 'type': 'function',
                    'function': {'name': 'execute_code', 'arguments': json.dumps({'code': cases[label][0]})},
                }]}
                finish = 'tool_calls'
            else:
                result = json.loads(results[-1]['content'])
                outcomes[label] = result
                assert label != 'slow', ('Cancelled cell reached the model', result)
                _, expected, reused, count = cases[label]
                assert result['status'] == 'ok', result
                if label == 'bridge-read':
                    bridged = json.loads(result['output'])
                    assert bridged['ok'] is True, bridged
                    assert any(t['title'] == 'Python bridge fixture' for t in bridged['result']['items']), bridged
                    assert result['tool_calls_made'] == 1, result
                else:
                    assert result['output'].strip() == expected, result
                kernel = result['kernel']
                assert kernel['mode'] == 'session' and kernel['ephemeral'] is True, result
                assert kernel['reused'] is reused and kernel['execution_count'] == count, result
                delta = {'role': 'assistant', 'content': 'Verified ' + label}
                finish = 'stop'
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            for value in [
                {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]},
            ]:
                await response.write(('data: ' + json.dumps(value) + '\n\n').encode())
            await response.write(b'data: [DONE]\n\n')
            await response.write_eof()
            return response

        app = web.Application()
        app.router.add_post('/v1/chat/completions', model)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        model_port = site._server.sockets[0].getsockname()[1]
        base = f'http://127.0.0.1:{port()}'
        env = os.environ.copy()
        env.update(ORIALIS_ENV='development', ORIALIS_HOST='127.0.0.1',
                   ORIALIS_PORT=base.rsplit(':', 1)[1], ORIALIS_PUBLIC_URL=base,
                   ORIALIS_DEV_DEVICE_AUTH='false',
                   ORIALIS_DATABASE_URL=f'sqlite://{directory}/server.sqlite?mode=rwc',
                   ORIALIS_UPLOAD_DIR=str(directory / 'uploads'),
                   ORIALIS_AGENT_DEVICE_TOKEN=TOKEN, ORIALIS_AGENT_USER_ID='full-owner')
        server_log = (directory / 'server.log').open('w+')
        agent_log = (directory / 'agent.log').open('w+')
        server = subprocess.Popen([str(args.server)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
        agent = None
        collector = None
        command = [str(binary), '--server', base.replace('http', 'ws') + '/api/v1/agent/ws',
                   '--device', 'TE_ST_Rust', '--token', TOKEN, '--db', str(directory / 'agent.sqlite'),
                   '--endpoint', f'http://127.0.0.1:{model_port}/v1/chat/completions',
                   '--verify-owner', '--expected-owner', 'full-owner', '--session-context',
                   '--stream-events', '--domain-tools', '--interactions', '--local-tools-json',
                   json.dumps({'root': str(workspace), 'write': 'allow', 'execute': 'ask',
                               'python_program': 'python', 'python_bridge_tools': ['list_tasks'], 'programs': [{'name': 'python', 'executable': '/usr/bin/python3'}]})]

        async def start():
            process = subprocess.Popen(command, stdout=agent_log, stderr=subprocess.STDOUT)
            for _ in range(500):
                if process.poll() is not None:
                    raise AssertionError('Agent exited during startup')
                devices = await asyncio.to_thread(api, base, 'GET', '/api/v1/agent/devices')
                if any(d['deviceId'] == 'TE_ST_Rust' and d['online'] for d in devices['devices']):
                    return process
                await asyncio.sleep(.02)
            process.terminate()
            process.wait(timeout=5)
            raise AssertionError('Agent startup timed out')

        async def send(conv, mid, body):
            return await asyncio.to_thread(api, base, 'POST', f'/api/v1/conversations/{conv}/messages', {'id': mid, 'content': body})

        async def finals(conv, count):
            for _ in range(1000):
                data = await asyncio.to_thread(api, base, 'GET', f'/api/v1/conversations/{conv}/messages?limit=500')
                found = [m for m in data['items'] if m['role'] == 'assistant' and m['id'].startswith('final_')]
                if len(found) >= count:
                    return found
                if collector and collector.done():
                    collector.result()
                assert agent.poll() is None, 'Agent exited'
                await asyncio.sleep(.02)
            raise AssertionError(('Missing final replies', conv, count, data, outcomes))

        async def cell(conv, label, count):
            before = len(approvals)
            await send(conv, 'input-' + label, 'PYCASE:' + label + ':END')
            result = await finals(conv, count)
            assert any(m['content'] == 'Verified ' + label for m in result), result
            assert len(approvals) == before + 1, ('Every fresh cell requires native once approval', approvals)
            assert label in outcomes
            return outcomes[label]

        try:
            for _ in range(500):
                try:
                    await asyncio.to_thread(api, base, 'GET', '/api/v1/health')
                    break
                except OSError:
                    await asyncio.sleep(.02)
            with sqlite3.connect(directory / 'server.sqlite') as db:
                db.execute("INSERT INTO users(id,username,password_hash) VALUES('full-owner','full-owner','synthetic-no-login')")
                db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('full-session','full-owner',?,'2099-01-01T00:00:00Z')", (hashlib.sha256(b'synthetic-mobile-session').hexdigest(),))
            await asyncio.to_thread(api, base, 'POST', '/api/v1/tasks', {'title': 'Python bridge fixture'})
            agent = await start()
            async with websockets.connect(base.replace('http', 'ws') + '/api/v1/ws', additional_headers={'Authorization': 'Session synthetic-mobile-session'}) as mobile:
                await mobile.send(json.dumps({'version': 1, 'type': 'hello', 'payload': {}}))
                assert json.loads(await mobile.recv())['type'] == 'hello.ack'

                async def collect():
                    async for raw in mobile:
                        envelope = json.loads(raw)
                        if envelope['type'] == 'ping':
                            await mobile.send(json.dumps({'version': 1, 'type': 'pong', 'payload': {}}))
                            continue
                        event = envelope.get('payload', {}).get('event', {})
                        if event:
                            events.append(event)
                        if event.get('type') == 'approval.request':
                            approvals.append(event)
                            await mobile.send(json.dumps({'version': 1, 'type': 'event', 'request_id': event['request_id'], 'payload': {'kind': 'approval.response', 'conversationId': envelope['payload'].get('conversationId', event.get('conversation_id')), 'decision': 'once'}}))

                collector = asyncio.create_task(collect())
                for conv in ['python-a', 'python-b']:
                    await asyncio.to_thread(api, base, 'POST', '/api/v1/conversations', {'id': conv, 'title': 'Synthetic Python fixture'})
                    await asyncio.to_thread(api, base, 'PUT', f'/api/v1/conversations/{conv}/agent-device', {'deviceId': 'TE_ST_Rust'})
                await cell('python-a', 'seed', 1)
                await cell('python-a', 'increment', 2)
                checks.append('fresh input IDs preserve Python variables and execution count with separate native once approvals')
                await cell('python-b', 'isolated', 1)
                checks.append('different conversation has an isolated fresh kernel')
                await cell('python-b', 'bridge-read', 2)
                checks.append('explicitly allowlisted hermes_tools.list_tasks callback reads actual owner-scoped server fixture')
                before = (len(calls), len(approvals))
                await send('python-a', 'input-increment', 'PYCASE:increment:END')
                await asyncio.sleep(.3)
                assert (len(calls), len(approvals)) == before
                await cell('python-a', 'probe-replay', 3)
                checks.append('same input HTTP replay causes no model/approval repeat or Python increment')
                await send('python-a', 'input-new', '/new')
                await finals('python-a', 4)
                await cell('python-a', 'after-new', 5)
                checks.append('/new resets Python state through actual main-agent session generation')
                await cell('python-a', 'before-restart', 6)
                agent.terminate()
                assert agent.wait(timeout=5) == 0
                agent = None
                await asyncio.sleep(.2)
                agent = await start()
                await cell('python-a', 'after-restart', 7)
                checks.append('service restart keeps durable conversation but explicitly returns fresh ephemeral Python kernel')
                await send('python-a', 'input-slow', 'PYCASE:slow:END')
                for _ in range(500):
                    if (workspace / 'cell-started.txt').exists():
                        break
                    if collector.done():
                        collector.result()
                    await asyncio.sleep(.02)
                assert (workspace / 'cell-started.txt').read_text() == 'actual cell running'
                started = time.monotonic()
                await send('python-a', 'input-stop', '/stop')
                stopped = await finals('python-a', 9)
                stop_seconds = time.monotonic() - started
                assert stop_seconds < 3, stop_seconds
                assert any('已取消' in m['content'] for m in stopped), stopped
                assert 'slow' not in outcomes
                await cell('python-a', 'after-stop', 10)
                checks.append('/stop cancels a demonstrably running sandboxed cell promptly and subsequent cell uses fresh state')
        except Exception:
            agent_log.seek(0)
            server_log.seek(0)
            print('AGENT LOG', agent_log.read())
            print('SERVER LOG', server_log.read()[-5000:])
            raise
        finally:
            if collector:
                collector.cancel()
                await asyncio.gather(collector, return_exceptions=True)
            if agent:
                agent.terminate()
                agent.wait(timeout=5)
            server.terminate()
            server.wait(timeout=5)
            await runner.cleanup()
        result = {'passed': len(checks), 'checks': checks, 'provider_calls': len(calls),
                  'native_once_approvals': len(approvals), 'stop_seconds': stop_seconds,
                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'server_sha256': hashlib.sha256(args.server.read_bytes()).hexdigest(),
                  'observed_tool_results': outcomes,
                  'limitations': 'Synthetic local owner and controlled model; actual server, native approval, main Agent, Bubblewrap Python. HTTP duplicate tests server ingress idempotency; direct core replay covered separately. No deployment or real user data.'}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=ROOT / 'hermes-rust-core/target/debug/orialis_agent')
    parser.add_argument('--server', type=Path, default=ROOT / 'orialis/target/release/orialis-server')
    parser.add_argument('--out', type=Path, default=ROOT / 'hermes-rust-core/results/python-main-e2e.json')
    asyncio.run(main(parser.parse_args()))
