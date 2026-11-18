#!/usr/bin/env python3
"""Actual Server -> Rust Agent -> approved sandbox Python, cold vs warm.

Synthetic loopback fixtures only. Both arms use the SAME new Rust binary; this
is not a Rust-versus-upstream-Hermes comparison. Run only in a quiet window.
"""
import argparse
import asyncio
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import sqlite3
import subprocess
import tempfile
import time

import aiohttp
from aiohttp import web
import websockets
from e2e_local_main import TOKEN
from e2e_workspace import ROOT, port

CODE = "bench_value = sum(i*i for i in range(1000))\nprint(bench_value)"
EXPECTED = "332833500\n"
ANSWER = "Verified Python benchmark cell."


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def percentiles(values):
    """Nearest-rank percentiles. p99 is the max for the default n=30."""
    values = sorted(values)
    if not values:
        return None
    return {'n': len(values), 'min': values[0], 'p50': values[math.ceil(.50 * len(values)) - 1],
            'p95': values[math.ceil(.95 * len(values)) - 1],
            'p99': values[math.ceil(.99 * len(values)) - 1], 'max': values[-1]}


def proc_stat(pid):
    # /proc/PID/stat fields 14..17 include self CPU and children already waited
    # for. Reading only parent/CPU/RSS metadata, never cmdline or environment.
    raw = Path(f'/proc/{pid}/stat').read_text()
    end = raw.rindex(')')
    fields = raw[end + 2:].split()
    return {'pid': int(pid), 'comm': raw[raw.index('(') + 1:end],
            'ppid': int(fields[1]), 'self_ticks': int(fields[11]) + int(fields[12]),
            'waited_ticks': int(fields[13]) + int(fields[14]),
            'start_ticks': int(fields[19]), 'rss_pages': int(fields[21])}


class TreeMeter:
    """Own processes only; retain unknown as null instead of reporting zero.

Summing each live node's self + waited-child ticks accounts for active and
already-reaped descendants without double-counting an active child. Validate
waited counters/identities again to detect reaping while the snapshot was read.
CPU has CLK_TCK granularity; summed RSS is sampled RSS, not PSS/true peak.
"""
    def __init__(self):
        self.roots = {}
        self.warnings = Counter()
        self.hz = os.sysconf('SC_CLK_TCK')
        self.page_kib = os.sysconf('SC_PAGE_SIZE') / 1024

    def register(self, name, process):
        self.roots[name] = (process.pid, proc_stat(process.pid)['start_ticks'])

    def snapshot(self, need_sandbox=False):
        start = time.perf_counter()
        for _ in range(3):
            catalog = {}
            for item in Path('/proc').iterdir():
                if item.name.isdecimal():
                    try:
                        catalog[int(item.name)] = proc_stat(int(item.name))
                    except (OSError, ValueError, IndexError):
                        pass  # Unrelated processes may disappear or be unreadable.
            result = {}
            retry = False
            for name, (pid, identity) in self.roots.items():
                root = catalog.get(pid)
                if root is None or root['start_ticks'] != identity:
                    self.warnings[f'{name}: root metadata unavailable or identity changed'] += 1
                    result[name] = None
                    continue
                chosen = {pid}
                while True:
                    children = {p for p, row in catalog.items() if row['ppid'] in chosen}
                    expanded = chosen | children
                    if expanded == chosen:
                        break
                    chosen = expanded
                nodes = [catalog[p] for p in sorted(chosen)]
                # A wait/reparent/exit between root and descendant reads can lose
                # or double count CPU. Retry a bounded number of times, never hide it.
                for old in nodes:
                    try:
                        now = proc_stat(old['pid'])
                    except (OSError, ValueError, IndexError):
                        retry = True
                        break
                    if any(old[key] != now[key] for key in ('start_ticks', 'ppid', 'waited_ticks')):
                        retry = True
                        break
                if retry:
                    break
                descendants = [row for row in nodes if row['pid'] != pid]
                sandbox_known = not (name == 'agent' and need_sandbox and
                                     (not descendants or sum(row['rss_pages'] for row in descendants) <= 0))
                if not sandbox_known:
                    self.warnings['agent: expected live sandbox tree not observable'] += 1
                child_ticks = root['waited_ticks'] + sum(
                    row['self_ticks'] + row['waited_ticks'] for row in descendants)
                result[name] = {
                    'self_cpu_seconds': root['self_ticks'] / self.hz,
                    'active_and_reaped_child_cpu_seconds': child_ticks / self.hz if sandbox_known else None,
                    'tree_cpu_seconds': (root['self_ticks'] + child_ticks) / self.hz if sandbox_known else None,
                    'self_rss_kib': root['rss_pages'] * self.page_kib,
                    'descendant_rss_kib': sum(row['rss_pages'] for row in descendants) * self.page_kib if sandbox_known else None,
                    'tree_rss_kib': sum(row['rss_pages'] for row in nodes) * self.page_kib if sandbox_known else None,
                    'descendant_count': len(descendants) if sandbox_known else None,
                    'owned_processes': [{'pid': row['pid'], 'start_ticks': row['start_ticks'],
                                         'comm': row['comm']} for row in nodes],
                }
            if not retry:
                return {'at': time.perf_counter(), 'scan_seconds': time.perf_counter() - start, 'actors': result}
        self.warnings['process tree changed during all three snapshot attempts'] += 1
        return {'at': time.perf_counter(), 'scan_seconds': time.perf_counter() - start,
                'actors': {name: None for name in self.roots}}


def cpu_delta(before, after, warnings):
    result = {}
    for actor in ('agent', 'server'):
        left, right = before['actors'].get(actor), after['actors'].get(actor)
        result[actor] = {}
        for field in ('self_cpu_seconds', 'active_and_reaped_child_cpu_seconds', 'tree_cpu_seconds'):
            a, b = (left or {}).get(field), (right or {}).get(field)
            if a is None or b is None or b + 1e-9 < a:
                result[actor][field] = None
                warnings[f'{actor}: {field} interval unavailable/nonmonotonic'] += 1
            else:
                result[actor][field] = max(0, b - a)
    return result


def peak_rss(samples):
    result = {}
    for actor in ('agent', 'server'):
        result[actor] = {}
        for field in ('self_rss_kib', 'descendant_rss_kib', 'tree_rss_kib'):
            values = [(sample['actors'].get(actor) or {}).get(field) for sample in samples]
            # At least one missing sample means this is not a reliable peak bound.
            result[actor][field] = max(values) if values and all(v is not None for v in values) else None
    return result


async def main(args):
    assert args.rounds >= 1 and args.cells_per_round >= 1
    assert args.rounds * args.cells_per_round <= 200, 'Keep this a bounded local benchmark'
    assert .001 <= args.poll_seconds <= .1 and .005 <= args.sample_seconds <= .5
    assert args.idle_seconds >= 1
    if args.out.exists():
        raise FileExistsError(f'Refusing to overwrite prior evidence: {args.out}')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    result = {'status': 'incomplete', 'version': 1, 'comparison': 'same new Rust Agent: cold reset=true versus warm reset=false',
              'configuration': {'rounds': args.rounds, 'cells_per_arm_per_round': args.cells_per_round,
                                'concurrency': 1, 'poll_seconds': args.poll_seconds,
                                'sample_seconds': args.sample_seconds, 'idle_seconds': args.idle_seconds,
                                'code': CODE, 'model_rounds_per_cell': 2, 'native_once_approvals_per_cell': 1},
              'cells': [], 'blocks': [], 'priming_cells': [], 'startup': {}, 'idle': [],
              'limitations': [
                  'Both arms are the same frozen Rust implementation, not an upstream Python Hermes baseline.',
                  'Actual loopback Server, Agent, mobile once approval and Bubblewrap Python; deterministic local model has no paid-provider or internet latency.',
                  'Latency ends when a GET returns the persisted final message; includes polling/HTTP observation, not mobile UI rendering.',
                  'p99 uses nearest-rank; with 30 samples it is only the observed maximum, not a reliable population tail estimate.',
                  'Fixed-load block throughput is closed-loop concurrency=1 and includes between-cell sampling overhead; no saturation/parallel scaling claim.',
                  'CPU is procfs tick-granularity self plus active/reaped-child CPU; RSS sums shared pages, is not PSS, and sampled peaks may miss short spikes.',
                  'Monitoring and controlled model run in the harness; their CPU is reported separately and not attributed to Rust.',
                  'Unknown/inconsistent sandbox samples are null with warnings; zero is never substituted for unavailable data.',
              ]}
    meter = TreeMeter()
    cases, model_calls, approvals, observations = {}, [], [], {}
    active_label = None
    active_samples = None
    collector = sampler = agent = server = runner = None
    failure = None
    harness_before = resource.getrusage(resource.RUSAGE_SELF)
    overall_start = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix='orialis-python-perf-') as temp:
        directory = Path(temp)
        agent_binary, server_binary = directory / 'agent', directory / 'server'
        shutil.copy2(args.binary, agent_binary)
        shutil.copy2(args.server, server_binary)
        result['agent_sha256'], result['server_sha256'] = sha256(agent_binary), sha256(server_binary)
        if args.expect_agent_sha:
            assert result['agent_sha256'] == args.expect_agent_sha
        if args.expect_server_sha:
            assert result['server_sha256'] == args.expect_server_sha
        workspace = directory / 'workspace'
        workspace.mkdir()
        server_log, agent_log = (directory / 'server.log').open('w+'), (directory / 'agent.log').open('w+')

        async def model(request):
            raw = await request.read()
            payload = json.loads(raw)
            messages = payload['messages']
            at = max(i for i, message in enumerate(messages) if message['role'] == 'user')
            match = re.search(r'PYPERF:([A-Za-z0-9_-]+):END', messages[at]['content'])
            assert match, messages[at]
            label = match.group(1)
            case = cases[label]
            assert label == active_label, 'Unexpected concurrent model request'
            tools = [m for m in messages[at:] if m['role'] == 'tool']
            number = sum(call['label'] == label for call in model_calls) + 1
            assert number in (1, 2)
            if not tools:
                assert number == 1
                delta = {'role': 'assistant', 'tool_calls': [{
                    'index': 0, 'id': 'python-benchmark-cell', 'type': 'function',
                    'function': {'name': 'execute_code', 'arguments': json.dumps({'code': CODE, 'reset': case['reset']})}}]}
                finish = 'tool_calls'
            else:
                assert number == 2 and len(tools) == 1
                value = json.loads(tools[0]['content'])
                assert value['status'] == 'ok' and value['output'] == EXPECTED, value
                assert value['kernel']['reused'] is case['expected_reused'], value
                assert value['kernel']['execution_count'] == case['expected_count'], value
                assert value['tool_calls_made'] == 0, value
                observations[label] = {'kernel': value['kernel'], 'duration_seconds': value['duration_seconds'],
                                       'output': value['output'], 'tool_result_bytes': len(tools[0]['content'].encode())}
                delta, finish = {'role': 'assistant', 'content': ANSWER}, 'stop'
            assert payload.get('stream') is True
            chunks = [('data: ' + json.dumps(value) + '\n\n').encode() for value in [
                {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]}]] + [b'data: [DONE]\n\n']
            model_calls.append({'label': label, 'round': number, 'request_body_bytes': len(raw),
                                'response_sse_body_bytes': sum(map(len, chunks)),
                                'message_count': len(messages),
                                'user_message_count': sum(m['role'] == 'user' for m in messages),
                                'tool_message_count': sum(m['role'] == 'tool' for m in messages)})
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            for chunk in chunks:
                await response.write(chunk)
            await response.write_eof()
            return response

        try:
            app = web.Application(client_max_size=8 * 1024 * 1024)
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
            session_timeout = aiohttp.ClientTimeout(total=5)
            async with aiohttp.ClientSession(headers={'Authorization': 'Bearer ' + TOKEN}, timeout=session_timeout) as http:
                async def api(method, path, body=None):
                    async with http.request(method, base + path, json=body) as response:
                        response.raise_for_status()
                        return await response.json()

                start = time.perf_counter()
                server = subprocess.Popen([str(server_binary)], env=env, stdout=server_log, stderr=subprocess.STDOUT)
                meter.register('server', server)
                for _ in range(500):
                    try:
                        await api('GET', '/api/v1/health')
                        break
                    except (aiohttp.ClientError, OSError):
                        assert server.poll() is None, 'Server exited during startup'
                        await asyncio.sleep(.02)
                else:
                    raise TimeoutError('Server readiness timeout')
                result['startup']['server_spawn_to_health_seconds'] = time.perf_counter() - start
                with sqlite3.connect(directory / 'server.sqlite') as db:
                    db.execute("INSERT INTO users(id,username,password_hash) VALUES('full-owner','full-owner','synthetic-no-login')")
                    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('full-session','full-owner',?,'2099-01-01T00:00:00Z')", (hashlib.sha256(b'synthetic-mobile-session').hexdigest(),))
                command = [str(agent_binary), '--server', base.replace('http', 'ws') + '/api/v1/agent/ws',
                           '--device', 'TE_ST_Rust', '--token', TOKEN, '--db', str(directory / 'agent.sqlite'),
                           '--endpoint', f'http://127.0.0.1:{model_port}/v1/chat/completions',
                           '--verify-owner', '--expected-owner', 'full-owner', '--session-context',
                           '--stream-events', '--domain-tools', '--interactions', '--local-tools-json',
                           json.dumps({'root': str(workspace), 'write': 'allow', 'execute': 'ask',
                                       'python_program': 'python', 'programs': [{'name': 'python', 'executable': '/usr/bin/python3'}]})]
                start = time.perf_counter()
                agent = subprocess.Popen(command, stdout=agent_log, stderr=subprocess.STDOUT)
                meter.register('agent', agent)
                for _ in range(500):
                    devices = await api('GET', '/api/v1/agent/devices')
                    if any(d['deviceId'] == 'TE_ST_Rust' and d['online'] for d in devices['devices']):
                        break
                    assert agent.poll() is None, 'Agent exited during startup'
                    await asyncio.sleep(.02)
                else:
                    raise TimeoutError('Agent readiness timeout')
                result['startup']['agent_spawn_to_registered_online_seconds'] = time.perf_counter() - start
                result['startup']['ready_resources'] = await asyncio.to_thread(meter.snapshot)

                async def sample_loop():
                    while True:
                        label = active_label
                        # A cold reset can legitimately have no live child during
                        # reap/start. Mandatory post-cell and idle snapshots
                        # separately verify that sandbox RSS is observable.
                        sample = await asyncio.to_thread(meter.snapshot, False)
                        if label == active_label and active_samples is not None:
                            active_samples.append(sample)
                        await asyncio.sleep(args.sample_seconds)

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
                            if event.get('type') == 'approval.request':
                                assert active_label is not None and active_label in cases
                                conv = envelope['payload'].get('conversationId', event.get('conversation_id'))
                                assert conv == cases[active_label]['conversation']
                                assert not any(a['label'] == active_label for a in approvals)
                                received = time.perf_counter()
                                await mobile.send(json.dumps({'version': 1, 'type': 'event', 'request_id': event['request_id'],
                                                              'payload': {'kind': 'approval.response', 'conversationId': conv, 'decision': 'once'}}))
                                approvals.append({'label': active_label, 'request_id': event['request_id'],
                                                  'received_at': received, 'response_sent_at': time.perf_counter()})

                    collector = asyncio.create_task(collect())
                    sampler = asyncio.create_task(sample_loop())

                    async def wait_final(conv, expected_count):
                        polls = 0
                        while polls < 6000:
                            if collector.done():
                                collector.result()
                            if sampler.done():
                                sampler.result()
                            assert agent.poll() is None and server.poll() is None
                            data = await api('GET', f'/api/v1/conversations/{conv}/messages?limit=500')
                            polls += 1
                            finals = [m for m in data['items'] if m['role'] == 'assistant' and m['id'].startswith('final_')]
                            if len(finals) >= expected_count:
                                assert len(finals) == expected_count
                                return finals, polls
                            await asyncio.sleep(args.poll_seconds)
                        raise TimeoutError(f'Persisted final timeout: {conv}/{expected_count}')

                    async def run_cell(round_index, arm, index, conv, priming=False):
                        nonlocal active_label, active_samples
                        label = f'r{round_index}-{arm}-' + ('prime' if priming else f'{index:03d}')
                        cases[label] = {'conversation': conv, 'reset': priming or arm == 'cold',
                                        'expected_reused': not priming and arm == 'warm',
                                        'expected_count': index + 2 if not priming and arm == 'warm' else 1}
                        active_label = label
                        active_samples = []
                        before = await asyncio.to_thread(meter.snapshot, not priming)
                        active_samples.append(before)
                        started = time.perf_counter()
                        await api('POST', f'/api/v1/conversations/{conv}/messages',
                                  {'id': 'input-' + label, 'content': 'PYPERF:' + label + ':END'})
                        accepted_at = time.perf_counter()
                        finals, polls = await wait_final(conv, 1 if priming else index + 2)
                        completed = time.perf_counter()
                        assert finals[-1]['content'] == ANSWER or all(f['content'] == ANSWER for f in finals)
                        assert label in observations
                        calls = [call for call in model_calls if call['label'] == label]
                        grants = [approval for approval in approvals if approval['label'] == label]
                        assert len(calls) == 2 and len(grants) == 1
                        after = await asyncio.to_thread(meter.snapshot, True)
                        active_samples.append(after)
                        record = {'label': label, 'round': round_index, 'arm': arm, 'index': index, 'priming': priming,
                                  'conversation': conv, 'reset': cases[label]['reset'],
                                  'latency_seconds': completed - started, 'submit_http_seconds': accepted_at - started,
                                  'persistence_get_polls': polls, 'sample_count': len(active_samples),
                                  'cpu_seconds': cpu_delta(before, after, meter.warnings),
                                  'sampled_peak_rss_kib': peak_rss(active_samples),
                                  'rss_samples': [{'at': s['at'], 'scan_seconds': s['scan_seconds'],
                                                   'actors': {actor: None if data is None else {key: value for key, value in data.items() if 'rss_' in key or key == 'descendant_count'}
                                                              for actor, data in s['actors'].items()}} for s in active_samples],
                                  'resources_before': before, 'resources_after': after,
                                  'sample_scan_seconds': sum(s['scan_seconds'] for s in active_samples),
                                  'model_calls': calls, 'native_once_approvals': len(grants),
                                  'approval_handler_seconds': grants[0]['response_sent_at'] - grants[0]['received_at'],
                                  'observed_tool_result': observations[label]}
                        active_label = active_samples = None
                        result['priming_cells' if priming else 'cells'].append(record)
                        return record

                    for round_index in range(args.rounds):
                        convs = {arm: f'python-perf-r{round_index}-{arm}' for arm in ('cold', 'warm')}
                        for conv in convs.values():
                            await api('POST', '/api/v1/conversations', {'id': conv, 'title': 'Synthetic equal-length Python benchmark'})
                            await api('PUT', f'/api/v1/conversations/{conv}/agent-device', {'deviceId': 'TE_ST_Rust'})
                        for arm in ('cold', 'warm'):
                            prime = await run_cell(round_index, arm, -1, convs[arm], priming=True)
                            if round_index == 0 and arm == 'cold':
                                result['startup']['first_cell_submit_to_persisted_final_seconds'] = prime['latency_seconds']
                        if round_index == 0:
                            active_samples = []
                            before = await asyncio.to_thread(meter.snapshot, True)
                            start = time.perf_counter()
                            await asyncio.sleep(args.idle_seconds)
                            after = await asyncio.to_thread(meter.snapshot, True)
                            result['idle'].append({'seconds': time.perf_counter() - start,
                                                   'cpu_seconds': cpu_delta(before, after, meter.warnings),
                                                   'resources_before': before, 'resources_after': after,
                                                   'sampled_peak_rss_kib': peak_rss([before] + active_samples + [after])})
                            active_samples = None
                        order = ('cold', 'warm') if round_index % 2 == 0 else ('warm', 'cold')
                        for arm in order:
                            before = await asyncio.to_thread(meter.snapshot, True)
                            start = time.perf_counter()
                            for index in range(args.cells_per_round):
                                await run_cell(round_index, arm, index, convs[arm])
                            elapsed = time.perf_counter() - start
                            after = await asyncio.to_thread(meter.snapshot, True)
                            result['blocks'].append({'round': round_index, 'arm': arm, 'order': list(order),
                                                     'cells': args.cells_per_round, 'wall_seconds': elapsed,
                                                     'fixed_load_cells_per_second': args.cells_per_round / elapsed,
                                                     'cpu_seconds': cpu_delta(before, after, meter.warnings)})
                        # Retire the two old kernels outside both timed arms. New
                        # equal-length conversations in the next round cannot
                        # exhaust the configured shared max_processes=4 slots.
                        for arm, conv in convs.items():
                            await api('POST', f'/api/v1/conversations/{conv}/messages',
                                      {'id': f'cleanup-r{round_index}-{arm}', 'content': '/new'})
                            await wait_final(conv, args.cells_per_round + 2)
                        await asyncio.sleep(.05)
                    # Matched history *positions/counts*, not falsely identical
                    # serialized bytes: reset flags, kernel metadata, counters,
                    # IDs and timings can differ and are measured below.
                    for round_index in range(args.rounds):
                        for index in range(args.cells_per_round):
                            pair = [next(c for c in result['cells'] if c['round'] == round_index and c['index'] == index and c['arm'] == arm)
                                    for arm in ('cold', 'warm')]
                            for call_index in (0, 1):
                                for field in ('message_count', 'user_message_count', 'tool_message_count'):
                                    assert pair[0]['model_calls'][call_index][field] == pair[1]['model_calls'][call_index][field], (round_index, index, field)
                    result['status'] = 'passed'
        except BaseException as error:
            failure = error
            result['failure'] = f'{type(error).__name__}: {error}'
        finally:
            for task in (collector, sampler):
                if task:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
            shutdown_start = time.perf_counter()
            if agent:
                agent.terminate()
                try:
                    result['agent_exit_code'] = await asyncio.to_thread(agent.wait, timeout=5)
                except subprocess.TimeoutExpired:
                    agent.kill()
                    result['agent_exit_code'] = await asyncio.to_thread(agent.wait, timeout=5)
                    meter.warnings['Agent required kill during cleanup'] += 1
            if server:
                server.terminate()
                try:
                    result['server_exit_code'] = await asyncio.to_thread(server.wait, timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    result['server_exit_code'] = await asyncio.to_thread(server.wait, timeout=5)
                    meter.warnings['Server required kill during cleanup'] += 1
            result['shutdown_seconds'] = time.perf_counter() - shutdown_start
            if runner:
                await runner.cleanup()
            server_log.close()
            agent_log.close()
            logs = args.out.parent / (args.out.stem + '-logs')
            logs.mkdir(exist_ok=False)
            shutil.copy2(directory / 'server.log', logs / 'server.log')
            shutil.copy2(directory / 'agent.log', logs / 'agent.log')
    result['warnings'] = dict(meter.warnings)
    result['process_cpu_tick_seconds'] = 1 / meter.hz
    result['overall_fixture_wall_seconds'] = time.perf_counter() - overall_start
    harness_after = resource.getrusage(resource.RUSAGE_SELF)
    result['harness_cpu_seconds'] = (harness_after.ru_utime + harness_after.ru_stime
                                     - harness_before.ru_utime - harness_before.ru_stime)
    result['summary'] = {}
    for arm in ('cold', 'warm'):
        cells = [c for c in result['cells'] if c['arm'] == arm]
        blocks = [b for b in result['blocks'] if b['arm'] == arm]
        block_seconds = sum(b['wall_seconds'] for b in blocks)
        calls = [call for cell in cells for call in cell['model_calls']]
        cpu = {}
        for actor in ('agent', 'server'):
            cpu[actor] = {}
            for field in ('self_cpu_seconds', 'active_and_reaped_child_cpu_seconds', 'tree_cpu_seconds'):
                values = [b['cpu_seconds'][actor][field] for b in blocks]
                cpu[actor][field] = sum(values) if values and all(v is not None for v in values) else None
        result['summary'][arm] = {'submit_to_persisted_final_seconds': percentiles([c['latency_seconds'] for c in cells]),
                                  'fixed_load_cells_per_second': len(cells) / block_seconds if block_seconds else None,
                                  'timed_block_wall_seconds': block_seconds, 'timed_block_cpu_seconds': cpu,
                                  'model_calls': len(calls), 'model_request_body_bytes': sum(c['request_body_bytes'] for c in calls),
                                  'model_response_sse_body_bytes': sum(c['response_sse_body_bytes'] for c in calls),
                                  'native_once_approvals': sum(c['native_once_approvals'] for c in cells)}
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: result[key] for key in ('status', 'agent_sha256', 'server_sha256', 'summary', 'warnings')}, indent=2))
    if failure:
        raise failure


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path, help='Frozen final Rust Agent binary')
    parser.add_argument('--server', type=Path, default=ROOT / 'hermes-rust-core/results/control-responsive-next/server-control-responsive')
    parser.add_argument('--out', required=True, type=Path, help='New result path; existing evidence is never overwritten')
    parser.add_argument('--expect-agent-sha')
    parser.add_argument('--expect-server-sha')
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--cells-per-round', type=int, default=10)
    parser.add_argument('--poll-seconds', type=float, default=.005)
    parser.add_argument('--sample-seconds', type=float, default=.02)
    parser.add_argument('--idle-seconds', type=float, default=1)
    asyncio.run(main(parser.parse_args()))
