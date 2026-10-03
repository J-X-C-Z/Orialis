#!/usr/bin/env python3
"""Verify real HTTP SSE publication/restart against a disposable local database.
Optional --sources reads freshly collected facts; default uses explicit fixtures.
Never calls a production endpoint.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', type=Path)
    parser.add_argument('--binary', type=Path, default=ROOT / 'target/debug/orialis-server')
    args = parser.parse_args()
    facts = json.loads(args.sources.read_text()) if args.sources else None
    checks = {}
    with tempfile.TemporaryDirectory(prefix='orialis-news-stream-') as directory:
        work = Path(directory)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        secret = uuid.uuid4().hex
        env = os.environ.copy()
        env.update(ORIALIS_HOST='127.0.0.1', ORIALIS_PORT=str(port),
                   ORIALIS_ENV='development', ORIALIS_NEWS_PUBLISHER_TOKEN=secret,
                   ORIALIS_NEWS_PUBLISHER_USER_ID='unbound',
                   ORIALIS_DATABASE_URL=f'sqlite://{work}/test.db?mode=rwc',
                   ORIALIS_UPLOAD_DIR=str(work/'uploads'))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        proc = None
        streams = []
        with (work/'server.log').open('w') as log:
            def call(method, path, body=None, auth=None, expected=200):
                headers = {'Content-Type': 'application/json'}
                if auth: headers['Authorization'] = auth
                request = urllib.request.Request(base+path, method=method, headers=headers,
                    data=json.dumps(body).encode() if body is not None else None)
                try:
                    with opener.open(request, timeout=15) as response:
                        status, result = response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    status, result = error.code, json.load(error)
                assert status == expected, (path, status, result)
                return result

            def start():
                nonlocal proc
                proc = subprocess.Popen([str(args.binary.resolve())], cwd=work, env=env, stdout=log, stderr=log)
                for _ in range(100):
                    try:
                        call('GET', '/api/health')
                        return
                    except (urllib.error.URLError, ConnectionError): time.sleep(.1)
                raise RuntimeError('isolated server did not start')

            def stop():
                nonlocal proc
                if proc is not None:
                    proc.terminate()
                    proc.wait(5)
                    proc = None

            def connect(auth, revision=None):
                headers = {'Authorization': auth, 'Accept': 'text/event-stream'}
                if revision: headers['Last-Event-ID'] = revision
                response = opener.open(urllib.request.Request(base+'/api/v1/news/stream', headers=headers), timeout=5)
                assert response.headers['X-Accel-Buffering'] == 'no'
                streams.append(response)
                return response

            def event(response):
                fields = {}
                while True:
                    line = response.readline().decode().rstrip('\r\n')
                    if not line and fields.get('data'):
                        value = json.loads(fields['data'])
                        assert fields['event'] == 'news.updated'
                        assert fields['id'] == value['revision']
                        return fields['id']
                    if ': ' in line and not line.startswith(':'):
                        key, value = line.split(': ', 1)
                        fields[key] = value

            def publish(path, result, source, **extra):
                task = uuid.uuid4().hex
                body = {'taskId': task, 'idempotencyKey': task, 'source': source,
                        'generatedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
                        'result': result, **extra}
                receipt = call('POST', '/api/v1/news'+path, body, 'Bearer '+secret)
                assert receipt['status'] == 'succeeded'
                return body

            try:
                start()
                a = call('POST', '/api/v1/auth/register', {'username':'stream_'+uuid.uuid4().hex[:8], 'password':uuid.uuid4().hex}, expected=201)
                env['ORIALIS_NEWS_PUBLISHER_USER_ID'] = a['userId']
                stop(); start()
                auth = 'Session '+a['accessToken']
                call('GET', '/api/v1/news/stream', expected=401)
                first, second = connect(auth), connect(auth)
                assert event(first) == event(second)
                checks['session_auth_and_two_clients'] = True
                hot = facts['aihot']['hot'] if facts else [{'id':'explicit-test','title':'Integration fixture'}]
                publish('/publish/aihot/hot', hot, 'aihot.news')
                cursor = event(first)
                assert cursor == event(second)
                assert call('GET','/api/v1/news/aihot/hot',auth=auth)['data'] == hot
                checks['aihot_publish_stream_readback'] = True
                for period in ('daily','weekly'):
                    result = facts['github'][period] if facts else {
                        'repositories':[{'repository':'fixture/test','repositoryUrl':'https://github.com/fixture/test','description':'Explicit test data'}],
                        'brief':{'title':'Fixture '+period,'summary':'Synthetic transport check','themes':[], 'highlights':[], 'analysisStatus':'unavailable', 'source':'githot.dev'}}
                    publish('/publish/github/'+period, result, 'githot.dev', period=period)
                    changed = event(first)
                    assert changed != cursor and changed == event(second)
                    cursor = changed
                    assert call('GET','/api/v1/news/github/'+period,auth=auth)['data'] == result['repositories']
                    assert call('GET','/api/v1/news/github/briefs/'+period,auth=auth)['data'] == result['brief']
                    checks['github_'+period+'_stream_atomic_readback'] = True
                for stream in streams: stream.close()
                streams.clear()
                stop(); start()
                persisted = call('GET','/api/v1/news/github/daily',auth=auth)['data']
                assert persisted
                # A reconnect from an older cursor receives the current revision.
                restored = connect(auth, '0'*64)
                assert event(restored) == cursor
                checks['restart_persistence_and_reconnect_reconciliation'] = True
            finally:
                for stream in streams: stream.close()
                stop()
    evidence = {'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                'sourceMode':'fresh collected source facts' if facts else 'explicit synthetic transport fixtures',
                'checks':checks, 'productionChanged':False}
    destination = ROOT/'news/evidence/realtime-http-20261003.json'
    destination.write_text(json.dumps(evidence, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(evidence, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
