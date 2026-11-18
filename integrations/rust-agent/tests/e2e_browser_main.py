#!/usr/bin/env python3
"""Actual authenticated Orialis Server + actual main, SYNTHETIC CDP only.

No Chromium launch, real browser, signed-in profile, live account, or deployment.
Synthetic CDP verifies routing/permissions/lifecycle, never rendering or egress
sandboxing. All temporary services and clients run in this one invocation.
"""
import argparse
import asyncio
import base64
import contextlib
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import statistics
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zlib

from aiohttp import web
import websockets
from e2e_workspace import ROOT, port

TOKEN = 'synthetic-browser-main-token'
DEVICE = 'TE_ST_Rust'
TEXT = '<script>not executable</script> & local fixture 中文'


def png():
    def chunk(tag, data):
        return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1, 1, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\x00\x20\x80\xe0\xff')) + chunk(b'IEND', b''))


def api(base, method, path, body=None, authorization='Bearer ' + TOKEN):
    request = urllib.request.Request(
        base + path, data=json.dumps(body).encode() if body is not None else None,
        method=method, headers={'Content-Type': 'application/json', 'Authorization': authorization})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def process_sample(process):
    """Read only our spawned agent, never unrelated process information."""
    stat = Path(f'/proc/{process.pid}/stat').read_text().rsplit(')', 1)[1].split()
    status = Path(f'/proc/{process.pid}/status').read_text()
    memory = {}
    for line in status.splitlines():
        if line.startswith(('VmRSS:', 'VmHWM:')):
            name, value, unit = line.split()
            assert unit == 'kB'
            memory[name.rstrip(':') + '_kib'] = int(value)
    return {'cpu_ms': (int(stat[11]) + int(stat[12])) * 1000 / os.sysconf('SC_CLK_TCK'),
            'wall_ms': time.perf_counter() * 1000, **memory}


def process_interval(before, after):
    return {'cpu_ms': after['cpu_ms'] - before['cpu_ms'],
            'wall_ms': after['wall_ms'] - before['wall_ms'],
            'rss_start_kib': before['VmRSS_kib'], 'rss_end_kib': after['VmRSS_kib'],
            'peak_rss_kib': after['VmHWM_kib'],
            'cpu_clock_tick_ms': 1000 / os.sysconf('SC_CLK_TCK')}


async def eventually(predicate, timeout=6):
    end = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < end, 'condition timed out'
        await asyncio.sleep(.01)


class SyntheticCdp:
    def __init__(self):
        self.commands = []
        self.connections = 0
        self.closed = set()
        self.live = set()
        self.hang_dom = False
        self.dom_entered = asyncio.Event()
        self.errors = []

    def count(self, method):
        return sum(v['method'] == method for _, v in self.commands)

    async def handle(self, ws):
        self.connections += 1
        connection = self.connections
        self.live.add(connection)
        targets = 0
        rendered = {}
        try:
            assert ws.request.path == '/devtools/browser/synthetic'
            async for raw in ws:
                value = json.loads(raw)
                method = value['method']
                self.commands.append((connection, value))
                result = {}
                if method == 'Target.createBrowserContext':
                    assert value['params'] == {'disposeOnDetach': True}
                    result = {'browserContextId': f'context-{connection}'}
                elif method == 'Target.createTarget':
                    assert value['params']['browserContextId'] == f'context-{connection}'
                    assert value['params']['url'] == 'about:blank'
                    targets += 1
                    result = {'targetId': f'target-{connection}-{targets}'}
                elif method == 'Target.attachToTarget':
                    assert value['params']['targetId'] == f'target-{connection}-{targets}'
                    result = {'sessionId': f'page-{connection}-{targets}'}
                elif method == 'Target.closeTarget':
                    assert value['params']['targetId'].startswith(f'target-{connection}-')
                    result = {'success': True}
                elif method == 'Browser.setDownloadBehavior':
                    assert value['params'] == {'behavior': 'deny', 'browserContextId': f'context-{connection}'}
                elif method == 'Browser.resetPermissions':
                    assert value['params']['browserContextId'] == f'context-{connection}'
                elif method == 'Page.getFrameTree':
                    result = {'frameTree': {'frame': {'id': f'frame-{connection}'}}}
                elif method == 'Page.setDocumentContent':
                    document = value['params']['html']
                    assert value['params']['frameId'] == f'frame-{connection}'
                    assert '<script>not executable</script>' not in document
                    assert "default-src &#39;none&#39;" in document or "default-src 'none'" in document
                    rendered[value['sessionId']] = html.unescape(re.search(r'<pre[^>]*>(.*?)</pre>', document, re.S).group(1))
                elif method == 'DOM.getDocument':
                    self.dom_entered.set()
                    if self.hang_dom:
                        continue
                    text = rendered.get(value['sessionId'], f'owned synthetic context {connection}')
                    result = {'root': {'nodeName': '#document', 'children': [
                        {'nodeName': 'BODY', 'children': [
                            {'nodeName': '#text', 'nodeValue': text},
                            {'nodeName': 'INPUT', 'attributes': ['value', 'synthetic-secret']},
                            {'nodeName': 'SCRIPT', 'children': [{'nodeName': '#text', 'nodeValue': 'hidden-script'}]},
                        ]}]}}
                elif method == 'Page.captureScreenshot':
                    result = {'data': base64.b64encode(png()).decode()}
                elif method == 'Page.navigate':
                    assert value['params']['url'] == 'about:blank'
                else:
                    assert method in {
                        'Network.enable', 'Network.setBlockedURLs', 'Network.setBypassServiceWorker',
                        'Network.emulateNetworkConditions', 'Emulation.setScriptExecutionDisabled',
                        'Fetch.enable', 'Page.enable', 'Emulation.setDeviceMetricsOverride', 'Target.setAutoAttach',
                    }, f'unsupported CDP method dispatched: {method}'
                if 'sessionId' in value:
                    assert value['sessionId'].startswith(f'page-{connection}-')
                response = {'id': value['id'], 'result': result}
                if 'sessionId' in value:
                    response['sessionId'] = value['sessionId']
                await ws.send(json.dumps(response))
        except websockets.ConnectionClosed:
            pass
        except Exception as error:
            self.errors.append(repr(error))
            raise
        finally:
            self.live.discard(connection)
            self.closed.add(connection)


class OwnerHost:
    def __init__(self, root, owner, binary, server_binary, model_endpoint, cdp_endpoint):
        self.root = root / owner
        self.root.mkdir(mode=0o700)
        self.owner = owner
        self.binary = binary
        self.server_binary = server_binary
        self.model_endpoint = model_endpoint
        self.cdp_endpoint = cdp_endpoint
        self.base = f'http://127.0.0.1:{port()}'
        self.server = None
        self.agent = None
        self.mobile = None
        self.reader = None
        self.approvals = asyncio.Queue()
        self.envelopes = []
        self.sent = 0
        self.server_log = (self.root / 'server.log').open('w+')
        self.agent_log = (self.root / 'agent.log').open('w+')

    async def http(self, method, path, body=None):
        return await asyncio.to_thread(api, self.base, method, path, body)

    async def start_server(self):
        env = os.environ.copy()
        env.update(ORIALIS_ENV='development', ORIALIS_HOST='127.0.0.1',
                   ORIALIS_PORT=self.base.rsplit(':', 1)[1], ORIALIS_PUBLIC_URL=self.base,
                   ORIALIS_DEV_DEVICE_AUTH='false', ORIALIS_DATABASE_URL=f'sqlite://{self.root}/server.sqlite?mode=rwc',
                   ORIALIS_UPLOAD_DIR=str(self.root / 'uploads'), ORIALIS_AGENT_DEVICE_TOKEN=TOKEN,
                   ORIALIS_AGENT_USER_ID=self.owner)
        self.server = subprocess.Popen([str(self.server_binary)], env=env, stdout=self.server_log, stderr=subprocess.STDOUT)
        for _ in range(500):
            try:
                await self.http('GET', '/api/v1/health')
                break
            except OSError:
                assert self.server.poll() is None
                await asyncio.sleep(.02)
        else:
            raise AssertionError('server startup timed out')
        with sqlite3.connect(self.root / 'server.sqlite') as db:
            for owner in [self.owner, 'foreign-user']:
                db.execute('INSERT OR IGNORE INTO users(id,username,password_hash) VALUES(?,?,?)', (owner, owner, 'synthetic-no-login'))
                token = f'mobile-{owner}'
                db.execute("INSERT OR IGNORE INTO user_sessions(id,user_id,token_hash,expires_at) VALUES(?,?,?,'2099-01-01T00:00:00Z')",
                           (token, owner, hashlib.sha256(token.encode()).hexdigest()))
        assert (await self.http('GET', '/api/v1/auth/session'))['userId'] == self.owner
        self.mobile = await websockets.connect(self.base.replace('http', 'ws') + '/api/v1/ws',
                                               additional_headers={'Authorization': f'Session mobile-{self.owner}'})
        await self.mobile.send(json.dumps({'version': 1, 'type': 'hello', 'payload': {}}))
        assert json.loads(await self.mobile.recv())['type'] == 'hello.ack'
        async def reader():
            async for raw in self.mobile:
                envelope = json.loads(raw)
                self.envelopes.append(envelope)
                if envelope['type'] == 'ping':
                    await self.mobile.send(json.dumps({'version': 1, 'type': 'pong', 'payload': {}}))
                event = envelope.get('payload', {}).get('event', {})
                if event.get('type') == 'approval.request':
                    event['_fixture_conversation'] = envelope.get('payload', {}).get('conversationId')
                    await self.approvals.put(event)
        self.reader = asyncio.create_task(reader())

    async def restart_server(self):
        await self.mobile.close()
        with contextlib.suppress(websockets.ConnectionClosed):
            await self.reader
        self.mobile = None
        self.reader = None
        self.server.terminate()
        await asyncio.to_thread(self.server.wait, 5)
        await self.start_server()
        for _ in range(500):
            assert self.agent.poll() is None, self.logs()
            devices = await self.http('GET', '/api/v1/agent/devices')
            if any(v['deviceId'] == DEVICE and v['online'] for v in devices['devices']):
                return
            await asyncio.sleep(.02)
        raise AssertionError('agent reconnect timed out')

    def command(self, enabled=True, expected=None, db=None):
        command = [str(self.binary), '--server', self.base.replace('http', 'ws') + '/api/v1/agent/ws',
                   '--device', DEVICE, '--token', TOKEN, '--db', str(db or self.root / 'agent.sqlite'),
                   '--endpoint', self.model_endpoint, '--verify-owner', '--expected-owner', expected or self.owner,
                   '--session-context', '--stream-events', '--interactions', '--attachments', '--output-files']
        if enabled:
            command += ['--browser-tools-json', json.dumps({'mode': 'restricted_local_render',
                        'disposable_endpoint': self.cdp_endpoint, 'rpc_timeout_ms': 3000, 'max_sessions': 4})]
        return command

    async def start_agent(self, enabled=True):
        began = time.perf_counter()
        self.agent = subprocess.Popen(self.command(enabled), stdout=self.agent_log, stderr=subprocess.STDOUT)
        for _ in range(500):
            assert self.agent.poll() is None, self.logs()
            devices = await self.http('GET', '/api/v1/agent/devices')
            if any(v['deviceId'] == DEVICE and v['online'] for v in devices['devices']):
                self.startup_ms = (time.perf_counter() - began) * 1000
                return
            await asyncio.sleep(.02)
        raise AssertionError('agent startup timed out')

    async def stop_agent(self):
        if self.agent:
            self.agent.terminate()
            assert await asyncio.to_thread(self.agent.wait, 5) == 0, self.logs()
            self.agent = None
            await asyncio.sleep(.05)

    async def create(self, conversation='same-conversation'):
        await self.http('POST', '/api/v1/conversations', {'id': conversation, 'title': 'Disposable browser fixture'})
        await self.http('PUT', f'/api/v1/conversations/{conversation}/agent-device', {'deviceId': DEVICE})

    async def send(self, content, conversation='same-conversation'):
        self.sent += 1
        mid = f'{self.owner}-{self.sent}'
        await self.http('POST', f'/api/v1/conversations/{conversation}/messages', {'id': mid, 'content': content})
        return mid

    async def final(self, mid, conversation='same-conversation'):
        for _ in range(600):
            messages = await self.http('GET', f'/api/v1/conversations/{conversation}/messages?limit=500')
            found = [v for v in messages['items'] if v['role'] == 'assistant' and v.get('replyToMessageId') == mid]
            if found:
                return found[-1]
            assert self.agent and self.agent.poll() is None, self.logs()
            await asyncio.sleep(.01)
        raise AssertionError({'missing_final': mid, 'messages': messages, 'logs': self.logs()})

    async def turn(self, content, conversation='same-conversation'):
        start = time.perf_counter()
        result = await self.final(await self.send(content, conversation), conversation)
        return result, (time.perf_counter() - start) * 1000

    async def approval(self, mid, conversation='same-conversation'):
        while True:
            event = await asyncio.wait_for(self.approvals.get(), 8)
            if event['_fixture_conversation'] == conversation:
                return event

    async def decide(self, event, decision='once', conversation=None):
        await self.mobile.send(json.dumps({'version': 1, 'type': 'event', 'request_id': event['request_id'],
                              'payload': {'kind': 'approval.response', 'conversationId': conversation or event['_fixture_conversation'], 'decision': decision}}))

    def logs(self):
        self.agent_log.flush()
        self.agent_log.seek(0)
        self.server_log.flush()
        self.server_log.seek(0)
        return {'agent': self.agent_log.read()[-5000:], 'server': self.server_log.read()[-3000:]}

    async def close(self):
        await self.stop_agent()
        if self.mobile:
            await self.mobile.close()
        if self.reader:
            with contextlib.suppress(websockets.ConnectionClosed):
                await self.reader
        if self.server:
            self.server.terminate()
            await asyncio.to_thread(self.server.wait, 5)
        self.agent_log.close()
        self.server_log.close()


async def main(args):
    checks = []
    calls = []
    outcomes = {}
    handles = {}
    browser_enabled = {'owner-a': False, 'owner-b': True}
    cdp = SyntheticCdp()
    latencies = {}
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix='orialis-browser-main-') as directory:
        root = Path(directory)
        binary = root / 'agent'
        shutil.copy2(args.binary, binary)
        binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
        cdp_server = await websockets.serve(cdp.handle, '127.0.0.1', 0, max_size=16 * 1024 * 1024)
        cdp_endpoint = f'ws://127.0.0.1:{cdp_server.sockets[0].getsockname()[1]}/devtools/browser/synthetic'

        async def model(request):
            payload = await request.json()
            calls.append(payload)
            messages = payload['messages']
            at = max(i for i, value in enumerate(messages) if value['role'] == 'user')
            content = messages[at]['content']
            assert isinstance(content, str), 'browser must never silently emit model image pixels'
            owner, action = content.split(':', 1)
            tools = [value for value in messages[at:] if value['role'] == 'tool']
            names = {v['function']['name'] for v in payload.get('tools', [])}
            assert ('browser' in names) == browser_enabled[owner]
            assert ('browser_dialog' in names) == browser_enabled[owner]
            assert not names.intersection({'browser_exec', 'browser_cdp', 'browser_vault'})
            if browser_enabled[owner]:
                schema = next(v for v in payload['tools'] if v['function']['name'] == 'browser')['function']
                assert 'Restricted local render' in schema['description']
                assert 'screenshot' in schema['parameters']['properties']['action']['enum']
            outcome = json.loads(tools[-1]['content']) if tools else None
            if outcome is not None:
                outcomes.setdefault(content, []).append(outcome)
            name = 'browser'
            arguments = None
            answer = 'ok: ' + action
            if action.startswith('plain'):
                pass
            elif action.startswith('create'):
                if not tools:
                    arguments = {'action': 'new_tab'}
                else:
                    assert outcome['success']
                    handles[owner] = outcome['tab_id']
            elif action in {'render-deny', 'render-cancel', 'render-allow'}:
                if not tools:
                    arguments = {'action': 'render_text', 'tab_id': handles[owner], 'title': 'Synthetic <title>', 'text': TEXT}
                elif action == 'render-deny':
                    assert not outcome.get('success')
                elif action == 'render-cancel':
                    assert not outcome.get('success'), 'cancelled render must not succeed'
                elif len(tools) == 1:
                    assert outcome['render_mode'] == 'escaped_plain_text'
                    arguments = {'action': 'snapshot', 'tab_id': handles[owner]}
                elif len(tools) == 2:
                    assert outcome['content_type'] == 'untrusted_page_content'
                    assert TEXT in outcome['text'] and 'synthetic-secret' not in json.dumps(outcome)
                    arguments = {'action': 'screenshot', 'tab_id': handles[owner]}
                else:
                    assert outcome['success'] and not outcome['uploaded'] and not outcome['vision_analysis']
                    assert outcome['model_visibility'] == 'artifact_reference_only'
                    answer = 'Synthetic image artifact.\nMEDIA:artifact://' + outcome['artifact']['artifact_id']
            elif action in {'steal', 'snapshot', 'hang-snapshot', 'stale-tab'}:
                if not tools:
                    arguments = {'action': 'snapshot', 'tab_id': handles['owner-a'] if action == 'steal' else handles[owner]}
                elif action in {'steal', 'stale-tab'}:
                    assert not outcome.get('success')
                else:
                    assert outcome['success']
            elif action == 'tabs-empty':
                if not tools:
                    arguments = {'action': 'tabs'}
                else:
                    assert outcome['tabs'] == []
            elif action in {'external', 'raw-exec', 'raw-cdp', 'vault'}:
                if not tools:
                    if action == 'external':
                        arguments = {'action': 'navigate', 'tab_id': 'never-a-real-tab', 'url': 'https://example.com/'}
                    else:
                        name = {'raw-exec': 'browser_exec', 'raw-cdp': 'browser_cdp', 'vault': 'browser_vault'}[action]
                        arguments = {'code': 'document.cookie', 'method': 'Network.getCookies'}
                else:
                    assert not outcome.get('success')
            else:
                raise AssertionError(content)
            if arguments is not None:
                delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': f'call-{len(tools)}', 'type': 'function',
                         'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
                finish = 'tool_calls'
            else:
                delta = {'role': 'assistant', 'content': answer}
                finish = 'stop'
            if payload.get('stream'):
                response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
                await response.prepare(request)
                for value in [{'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                              {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]}]:
                    await response.write(('data: ' + json.dumps(value) + '\n\n').encode())
                await response.write(b'data: [DONE]\n\n')
                await response.write_eof()
                return response
            return web.json_response({'choices': [{'message': delta, 'finish_reason': finish}]})

        app = web.Application()
        app.router.add_post('/v1/chat/completions', model)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        endpoint = f'http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}/v1/chat/completions'
        a = OwnerHost(root, 'owner-a', binary, args.server, endpoint, cdp_endpoint)
        b = OwnerHost(root, 'owner-b', binary, args.server, endpoint, cdp_endpoint)
        try:
            await a.start_server()
            # Incorrect configured owner must fail before opening CDP or creating browser artifacts.
            rejected = subprocess.Popen(a.command(expected='foreign-user', db=a.root / 'wrong.sqlite'), stdout=a.agent_log, stderr=subprocess.STDOUT)
            assert await asyncio.to_thread(rejected.wait, 5) != 0
            assert cdp.connections == 0 and not (a.root / 'wrong.browser-artifacts').exists()
            checks.append('actual main rejected mismatched authenticated owner before browser construction or CDP connection')
            await a.start_agent(enabled=False)
            await a.create()
            latencies['disabled_startup_ms'] = a.startup_ms
            disabled_start = process_sample(a.agent)
            disabled = []
            for i in range(args.samples):
                _, elapsed = await a.turn(f'owner-a:plain-disabled-{i}')
                disabled.append(elapsed)
            disabled_process = process_interval(disabled_start, process_sample(a.agent))
            assert cdp.connections == 0 and not (a.root / 'agent.browser-artifacts').exists()
            checks.append('omitted browser opt-in preserved tool schemas, opened no CDP connection and created no browser state')
            await a.stop_agent()
            browser_enabled['owner-a'] = True
            await a.start_agent()
            latencies['enabled_startup_ms'] = a.startup_ms
            enabled_start = process_sample(a.agent)
            enabled = []
            for i in range(args.samples):
                _, elapsed = await a.turn(f'owner-a:plain-enabled-{i}')
                enabled.append(elapsed)
            enabled_process = process_interval(enabled_start, process_sample(a.agent))
            assert cdp.connections == 0
            checks.append('enabled main advertised restricted typed tools and connected lazily only on supported browser operations')
            for action in ['external', 'raw-exec', 'raw-cdp', 'vault']:
                await a.turn('owner-a:' + action)
            assert cdp.connections == 0 and a.approvals.empty()
            checks.append('external URL and browser_exec/browser_cdp/browser_vault attempts failed before CDP dispatch or approval')
            _, latencies['cold_create_ms'] = await a.turn('owner-a:create-first')
            assert cdp.connections == 1
            first_connection = cdp.connections
            mid = await a.send('owner-a:render-deny')
            event = await a.approval(mid)
            assert cdp.count('Page.setDocumentContent') == 0
            await a.decide(event, 'deny')
            await a.final(mid)
            await eventually(lambda: first_connection in cdp.closed)
            assert cdp.count('Page.setDocumentContent') == 0
            checks.append('actual mobile denial caused no document mutation and revoked the disposable CDP context')
            await a.turn('owner-a:create-approved')
            mid = await a.send('owner-a:render-allow')
            event = await a.approval(mid)
            await a.create('other-conversation')
            await a.decide(event, conversation='other-conversation')
            await asyncio.sleep(.1)
            assert cdp.count('Page.setDocumentContent') == 0
            # A foreign authenticated mobile user cannot approve owner-a's operation.
            async with websockets.connect(a.base.replace('http', 'ws') + '/api/v1/ws',
                    additional_headers={'Authorization': 'Session mobile-foreign-user'}) as foreign:
                await foreign.send(json.dumps({'version': 1, 'type': 'hello', 'payload': {}}))
                assert json.loads(await foreign.recv())['type'] == 'hello.ack'
                await foreign.send(json.dumps({'version': 1, 'type': 'event', 'request_id': event['request_id'],
                    'payload': {'kind': 'approval.response', 'conversationId': 'same-conversation', 'decision': 'once'}}))
                await asyncio.sleep(.1)
                assert cdp.count('Page.setDocumentContent') == 0
            checks.append('wrong-conversation and foreign-owner mobile approval could not authorize the pending action')
            await a.decide(event)
            screenshot_event = await a.approval(mid)
            assert screenshot_event['request_id'] != event['request_id']
            assert cdp.count('Page.captureScreenshot') == 0
            await a.decide(screenshot_event)
            final = await a.final(mid)
            assert final['content'] == 'Synthetic image artifact.' and len(final['attachments']) == 1, final
            attachment = final['attachments'][0]
            download = attachment.get('downloadUrl') or attachment.get('download_url')
            if download.startswith('/'):
                download = a.base + download
            def read_download():
                with urllib.request.urlopen(urllib.request.Request(download, headers={'Authorization': 'Bearer ' + TOKEN}), timeout=5) as response:
                    return response.read()
            assert await asyncio.to_thread(read_download) == png()
            assert list((a.root / 'agent.browser-artifacts').iterdir()) == []
            checks += ['exact one-use render approval escaped HTML and produced bounded untrusted DOM text',
                       'separate screenshot approval produced an immutable artifact and real authenticated Orialis download without model pixels']
            warm_start = process_sample(a.agent)
            dom_before = cdp.count('DOM.getDocument')
            warm = []
            for _ in range(args.samples):
                _, elapsed = await a.turn('owner-a:snapshot')
                warm.append(elapsed)
            warm_process = process_interval(warm_start, process_sample(a.agent))
            assert cdp.count('DOM.getDocument') - dom_before == args.samples
            latencies['synthetic_warm_snapshot_turn'] = {
                'samples': len(warm), 'median_ms': statistics.median(warm),
                'min_ms': min(warm), 'max_ms': max(warm), 'raw_ms': warm,
                'cdp_command_count': args.samples, 'agent_process': warm_process}
            # The same conversation ID at a distinct authenticated owner/server has distinct contexts.
            await b.start_server()
            await b.start_agent()
            await b.create()
            await b.turn('owner-b:create-first')
            assert handles['owner-a'] != handles['owner-b']
            before = cdp.count('DOM.getDocument')
            await b.turn('owner-b:steal')
            assert cdp.count('DOM.getDocument') == before
            await a.turn('owner-a:snapshot')
            checks.append('two actual authenticated owners with identical conversation IDs could not reuse each other’s opaque tab handle')
            # Transport loss revokes completed idle contexts, not only pending calls.
            prior_live = set(cdp.live)
            # owner-b's failed steal already revoked its context; owner-a is the only live one.
            assert len(prior_live) == 1
            await a.restart_server()
            await eventually(lambda: not (prior_live & cdp.live))
            reconnect_count = cdp.connections
            await a.turn('owner-a:tabs-empty')
            assert cdp.connections == reconnect_count + 1
            checks.append('actual Server restart revoked idle CDP contexts; verified reconnect created an empty context without restoring tabs')
            # Screenshot artifact references cannot be exported from another input.
            # Existing OutputFiles per-turn isolation is additionally unit-tested.
            before_connections = cdp.connections
            old_handle = handles['owner-a']
            await a.turn('/reset')
            await a.turn('owner-a:tabs-empty')
            assert cdp.connections == before_connections + 1
            assert handles['owner-a'] == old_handle
            await a.turn('owner-a:stale-tab')
            with sqlite3.connect(a.root / 'agent.sqlite') as database:
                generation = database.execute('SELECT generation FROM routes WHERE id=?',
                    (hashlib.sha256(b'same-conversation').hexdigest(),)).fetchone()[0]
                assert generation == 1
            checks.append('actual slash reset advanced durable generation, closed old context and rejected its old tab handle')
            await a.turn('owner-a:create-cancel')
            mid = await a.send('owner-a:render-cancel')
            event = await a.approval(mid)
            mutations = cdp.count('Page.setDocumentContent')
            connection = cdp.connections
            stop_mid = await a.send('/stop')
            await a.final(stop_mid)
            cancelled = await a.final(mid)
            assert '取消' in cancelled['content']
            await a.decide(event)
            await eventually(lambda: connection in cdp.closed)
            await asyncio.sleep(.1)
            assert cdp.count('Page.setDocumentContent') == mutations
            checks.append('actual slash stop revoked a pending browser approval; a late once response could not resurrect it')
            await a.turn('owner-a:create-hang')
            cdp.hang_dom = True
            cdp.dom_entered.clear()
            mid = await a.send('owner-a:hang-snapshot')
            await asyncio.wait_for(cdp.dom_entered.wait(), 5)
            connection = cdp.connections
            start = time.perf_counter()
            stop_mid = await a.send('/stop')
            await a.final(stop_mid)
            await a.final(mid)
            await eventually(lambda: connection in cdp.closed, timeout=2)
            latencies['inflight_cancel_ms'] = (time.perf_counter() - start) * 1000
            assert latencies['inflight_cancel_ms'] < 2000
            cdp.hang_dom = False
            checks.append('actual slash stop revoked an in-flight synthetic CDP RPC before its configured timeout without retry')
            await a.turn('owner-a:create-shutdown')
            await b.turn('owner-b:create-shutdown')
            assert len(cdp.live) == 2
            await a.stop_agent()
            await b.stop_agent()
            await eventually(lambda: not cdp.live)
            checks.append('SIGTERM shutdown of both actual main processes closed all owned synthetic CDP connections and drained cleanly')
            assert not cdp.errors, cdp.errors
            for _, command in cdp.commands:
                assert command['method'] not in {'Runtime.evaluate', 'Target.getTargets', 'Network.getCookies', 'Browser.close'}
            for group, samples, process in [('disabled_plain_turn', disabled, disabled_process), ('enabled_idle_plain_turn', enabled, enabled_process)]:
                latencies[group] = {'samples': len(samples), 'median_ms': statistics.median(samples),
                                    'min_ms': min(samples), 'max_ms': max(samples), 'raw_ms': samples,
                                    'agent_process': process}
        except Exception:
            import traceback
            traceback.print_exc()
            print('OWNER-A LOG', a.logs())
            print('OWNER-B LOG', b.logs())
            print('CDP ERRORS', cdp.errors)
            raise
        finally:
            await a.close()
            await b.close()
            cdp_server.close()
            await cdp_server.wait_closed()
            await runner.cleanup()
    result = {'passed': len(checks), 'checks': checks, 'binary_sha256': binary_sha,
              'server_sha256': hashlib.sha256(args.server.read_bytes()).hexdigest(),
              'source_sha256': {str(p.relative_to(ROOT / 'hermes-rust-core')): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [ROOT / 'hermes-rust-core' / name for name in
                          ['src/browser_host.rs', 'src/browser_tools.rs', 'src/bin/orialis_agent.rs', 'tests/e2e_browser_main.py']]},
              'provider_calls': len(calls), 'cdp_connections': cdp.connections,
              'cdp_command_count': len(cdp.commands), 'timings': latencies,
              'elapsed_seconds': time.perf_counter() - started,
              'limitations': 'Actual main + actual temporary Orialis Server/auth/mobile/OutputFiles, but only a synthetic CDP peer. '
                             'No actual Chromium, DOM/pixel rendering, external browser navigation, OS egress isolation or real-browser performance is validated. '
                             'Timings include real server HTTP/polling/model/receipt overhead and are smoke measurements, not a matched performance benchmark. '
                             'CPU/RSS are Linux procfs samples of only the spawned Rust Agent; CPU has clock-tick quantization and excludes Server/model/CDP peers. '}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=ROOT / 'hermes-rust-core/target/debug/orialis_agent')
    parser.add_argument('--server', type=Path, default=ROOT / 'orialis/target/release/orialis-server')
    parser.add_argument('--out', type=Path, default=ROOT / 'hermes-rust-core/results/next-browser-host/main-e2e.json')
    parser.add_argument('--samples', type=int, default=10)
    args = parser.parse_args()
    assert 1 <= args.samples <= 100
    asyncio.run(main(args))
