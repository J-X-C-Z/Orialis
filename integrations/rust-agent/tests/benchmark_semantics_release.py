#!/usr/bin/env python3
"""Hash-bound current semantics component and prior/current host observations.
Run only after all verification/build work stops. Does not build or call paid models.
"""
import argparse, hashlib, json, os, sys
from pathlib import Path
from benchmark_transactions_release import run, records
HERE = Path(__file__).resolve().parent

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main(a):
    a.out.mkdir(parents=True, exist_ok=False)
    release = a.release.resolve()
    manifest = json.loads((release/'manifest.json').read_text())
    tests = {r['target']: release/r['path'] for r in manifest['performance_test_binaries']}
    paths = {'candidate': release/'orialis_agent', 'baseline': a.baseline.resolve(),
             'server': a.server.resolve(), 'driver': Path(__file__).resolve(),
             'process_driver': HERE/'benchmark_transactions_release.py',
             'host_driver': HERE/'compare_final_host.py',
             'parent_driver': HERE/'e2e_parent_continuation_main.py',
             'original_server': a.original_server.resolve(),
             'file_test': tests['local_file_semantics'], 'skills_test': tests['skills_semantics'],
             'reply_test': tests['continuation_reply']}
    identities = {k: {'path': str(v), 'sha256': sha(v)} for k,v in paths.items()}
    assert identities['candidate']['sha256'] == manifest['binary_sha256']
    def unchanged():
        for k,v in identities.items(): assert sha(v['path']) == v['sha256'], k
    unchanged()
    (a.out/'identities.json').write_text(json.dumps(identities, indent=2))
    runs = []
    def save(): (a.out/'runs.json').write_text(json.dumps(runs, indent=2))
    command = [sys.executable, paths['host_driver'], '--baseline', paths['baseline'],
               '--candidate', paths['candidate'], '--server', paths['server'],
               '--out', a.out/'host', '--pairs', '4', '--iterations', '60', '--delays', '0', '20']
    runs.append(run(command, a.out/'host.log', timeout=900)); unchanged(); save()
    print('Prior/current host AB/BA complete', flush=True)
    for trial in range(4):
        cases = ['read_utf8', 'read_utf16', 'search_plain', 'search_ignored', 'directories']
        if trial % 2: cases.reverse()
        for case in cases:
            path = a.out/'files'/f'trial-{trial+1}-{case}.log'
            runs.append(run([paths['file_test'], '--ignored', '--exact',
                             'benchmark_local_file_semantics', '--nocapture'], path,
                            dict(os.environ, FILE_SEMANTICS_BENCH_CASE=case)))
            values = [v for v in records(path) if v.get('case') == case]
            assert len(values) == 1 and values[0]['iterations'] == 200, values
            path.with_suffix('.json').write_text(json.dumps(values[0], indent=2))
            unchanged(); save()
    print('Rooted file semantics observations complete', flush=True)
    for trial in range(4):
        path = a.out/'skills'/f'trial-{trial+1}.log'
        output = path.with_suffix('.json').resolve()
        runs.append(run([paths['skills_test'], '--ignored', '--exact',
                         'skill_catalog_observations', '--nocapture'], path,
                        dict(os.environ, HERMES_SKILL_SEMANTICS_BENCH_OUTPUT=str(output))))
        value = json.loads(output.read_text())
        assert len(value['raw_samples']) == 240
        unchanged(); save()
    print('Skill catalog observations complete', flush=True)
    for trial in range(3):
        path = a.out/'reply-outbox'/f'trial-{trial+1}.log'
        runs.append(run([paths['reply_test'], '--ignored', '--exact',
                         'benchmark_reply_outbox_overhead', '--nocapture'], path))
        values = [r for r in records(path) if r.get('retained_rows') == 256]
        assert len(values) == 1 and values[0]['payload_bytes'] == 4096
        path.with_suffix('.json').write_text(json.dumps(values[0], indent=2))
        unchanged(); save()
    print('Durable correlated reply outbox observations complete', flush=True)
    for trial in range(3):
        path = a.out/'parent-main'/f'trial-{trial+1}.log'
        output = path.with_suffix('.json').resolve()
        runs.append(run([sys.executable, paths['parent_driver'], '--binary', paths['candidate'],
                         '--server', paths['original_server'], '--out', output,
                         '--benchmark-iterations', '20', '--idle-seconds', '5'], path, timeout=300))
        value = json.loads(output.read_text())
        assert value['binary_sha256'] == identities['candidate']['sha256']
        assert value['server_sha256'] == identities['original_server']['sha256']
        assert value['benchmark']['iterations'] == 20 and value['idle_watchdog']
        unchanged(); save()
    print('Actual-main continuation and blocked-watchdog observations complete', flush=True)
    unchanged()
    (a.out/'complete.json').write_text(json.dumps({
        'complete': True, 'all_identities_unchanged': True, 'identities': identities,
        'limitations': [
            'Shared executor; project quiet window is not CPU or host isolation.',
            'Host matrix compares prior/current Rust releases with identical controlled provider responses; prompt/tool schema differences must be disclosed.',
            'Base/full host matrix does not enable opt-in parent resumption, browser or profile synchronization.',
            'File/skill measurements exercise current component test executables, not full main Agent; no equivalently scoped upstream speedup is claimed.',
            'Process resource observations cover executable self and separately labelled reaped-child CPU; short memory peaks may be missed.',
            'Parent-main fixture uses original Server and real-anchor persisted message.reply. Only exact message.ack received commits this transport; no proof of user read. Nonchat legacy notification fallback is not durable chat persistence.',
            'Blocked-watchdog idle phases are sequential same-process observations with CPU tick quantization; not randomized causal overhead estimates.'
        ]}, indent=2))

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    for name in ['release','baseline','server','original-server','out']: p.add_argument('--'+name, type=Path, required=True)
    main(p.parse_args())
