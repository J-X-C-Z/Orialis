#!/usr/bin/env python3
"""Balanced same-source isolated empty-router/reaper experiments.

This does not edit source or build. Call only in a coordinated quiet window.
The control is frozen 1c8f; each candidate identity is explicit and checked at
start/end of every run. Individual variants and the combination are all kept.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

from compare_host_releases import pool
from benchmark_integrated_profile import quantile

HARNESS = Path(__file__).with_name('profile_host_regression.py')
ORDERS = [
    ['control', 'empty', 'reaper', 'combined'],
    ['combined', 'reaper', 'empty', 'control'],
    ['empty', 'control', 'combined', 'reaper'],
    ['reaper', 'combined', 'control', 'empty'],
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(root):
    groups = {}
    for path in sorted(root.glob('delay-*/round-*/*/trial-*/*.json')):
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or not {'rows', 'workload', 'profile', 'requests'}.issubset(value):
            continue
        delay, _, label = path.relative_to(root).parts[:3]
        groups.setdefault((delay, label, value['profile'], value['workload']), []).append(value)
    rows = []
    for (delay, label, profile, workload), cases in sorted(groups.items()):
        measured = pool(cases)
        for field in ['submit_to_primary_ms', 'primary_actual_total_ms']:
            values = [r[field] for c in cases for r in c['rows'] if r['ok'] and r.get(field) is not None]
            measured[field] = {'observed': len(values), 'p50': quantile(values, .5), 'p95': quantile(values, .95)}
        rows.append({'delay': delay, 'variant': label, 'profile': profile, 'workload': workload, **measured})
    return rows


def main(a):
    a.out.mkdir(parents=True, exist_ok=False)
    paths = {name: getattr(a, name).resolve() for name in ['control', 'empty', 'reaper', 'combined', 'server']}
    paths.update(driver=Path(__file__).resolve(), harness=HARNESS.resolve(), integrated=HARNESS.with_name('benchmark_integrated_profile.py').resolve())
    identities = {name: {'path': str(path), 'sha256': sha(path)} for name, path in paths.items()}
    (a.out/'identities.json').write_text(json.dumps(identities, indent=2)+'\n')
    started = time.monotonic()
    runs = []
    for delay in a.delays:
        for round_index, order in enumerate(ORDERS):
            for label in order:
                for name, value in identities.items():
                    assert sha(Path(value['path'])) == value['sha256'], name+' changed'
                destination = a.out/f'delay-{delay:g}'/f'round-{round_index+1}'/label
                destination.parent.mkdir(parents=True, exist_ok=True)
                command = [sys.executable, str(HARNESS), '--binary', str(paths[label]), '--server', str(paths['server']), '--out', str(destination), '--iterations', str(a.iterations), '--idle-seconds', '.5', '--model-delay-ms', str(delay), '--proc-detail']
                runs.append({'delay_ms': delay, 'round': round_index+1, 'variant': label, 'command': command})
                (a.out/'runs.json').write_text(json.dumps(runs, indent=2)+'\n')
                with (destination.parent/(label+'.log')).open('w') as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
                print(f'delay={delay} round={round_index+1} {label} {time.monotonic()-started:.1f}s', flush=True)
    for name, value in identities.items():
        assert sha(Path(value['path'])) == value['sha256'], name+' changed'
    report = {'identities': identities, 'all_hashes_unchanged': True, 'seconds': time.monotonic()-started, 'summary': summarize(a.out),
              'limitations': ['Shared host, no isolation or confidence intervals.', 'Synthetic loopback primary/auxiliary models and mobile observer; no Flutter/WAN/live-model inference.', 'All feature variants included; binary layout changes may influence microbenchmarks.', 'CPU/RSS are whole process tree, not function-specific measurements.', 'Detailed memory snapshots run before measured batches.']}
    (a.out/'comparison.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['control', 'empty', 'reaper', 'combined', 'server', 'out']:
        p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--iterations', type=int, default=40)
    p.add_argument('--delays', type=float, nargs='+', default=[0, 20])
    args = p.parse_args()
    assert args.iterations > 0 and all(delay >= 0 for delay in args.delays)
    main(args)
