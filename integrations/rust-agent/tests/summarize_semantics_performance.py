#!/usr/bin/env python3
"""Summarize raw unchanged release observations without a causal speedup claim."""
import argparse, collections, json, math, statistics
from pathlib import Path

def q(xs):
    xs=sorted(xs);assert xs
    return {'count':len(xs),'p50':xs[math.ceil(.5*len(xs))-1], 'p95':xs[math.ceil(.95*len(xs))-1], 'p99':xs[math.ceil(.99*len(xs))-1], 'mean':statistics.mean(xs)}

def main(root):
    done=json.loads((root/'complete.json').read_text());assert done['complete'] and done['all_identities_unchanged']
    host=json.loads((root/'host/comparison.json').read_text());assert host['completed']
    result={'identities':done['identities'],'host_groups':host['groups'],'limitations':done['limitations'],
            'quantiles':'Nearest-rank pooled individual samples; repetitions retained separately. No confidence interval, isolated-host or causal improvement claim.'}
    result['host_requests']=sum(v[k]['requests'] for g in host['groups'] for v in g['summary'] for k in ('baseline','candidate'))
    result['host_failures']=sum(v[k]['failures'] for g in host['groups'] for v in g['summary'] for k in ('baseline','candidate'))
    assert result['host_requests']==3840 and result['host_failures']==0
    actors=collections.defaultdict(list)
    for g in host['groups']:
        for a in g['actors']:actors[(a['implementation'],a['profile'])].append(a)
    result['host_idle']=[{'implementation':k[0],'profile':k[1],'observations':len(rows),**{field:q([r[field] for r in rows]) for field in ['warm_rss_bytes','private_dirty_bytes','idle_cpu_ms','startup_online_ms','threads','fds']}} for k,rows in sorted(actors.items())]
    files=collections.defaultdict(list)
    for path in (root/'files').glob('trial-*.json'):
        if not path.name.endswith('process.json'):
            r=json.loads(path.read_text());files[r['case']].append(r)
    result['files']=[]
    for case,rows in sorted(files.items()):
        assert len(rows)==4
        elapsed=[s/1e6 for row in rows for s in row['elapsed_ns']]
        cpu=[s/1e6 for row in rows for s in row['cpu_ns']]
        assert len(elapsed)==800
        result['files'].append({'case':case,'latency_ms':q(elapsed),'cpu_ms':q(cpu),'scope':rows[0]['scope']})
    skills=collections.defaultdict(list)
    for path in (root/'skills').glob('trial-*.json'):
        if not path.name.endswith('process.json'):
            for r in json.loads(path.read_text())['raw_samples']:
                skills[(r['documents'],r['source'],r['operation'])].append(r)
    result['skills']=[]
    for (count,source,operation),rows in sorted(skills.items()):
        assert len(rows)==120
        result['skills'].append({'documents':count,'source':source,'operation':operation,'latency_ms':q([r['wall_us']/1000 for r in rows]),'cpu_ms':q([r['cpu_us']/1000 for r in rows]),'response_bytes':sorted(set(r['response_bytes'] for r in rows))})
    parent=[json.loads(p.read_text()) for p in sorted((root/'parent-main').glob('trial-*.json')) if not p.name.endswith('process.json')]
    assert len(parent)==3
    samples=[r for p in parent for r in p['benchmark']['raw_samples']];assert len(samples)==60
    result['parent_main']={'tasks':60,'latency_ms':{key:q([r[key] for r in samples]) for key in ['child_release_to_parent_provider_ms','parent_provider_to_mobile_final_ms','child_release_to_mobile_final_ms']},
                          'agent_cpu_ms_per_complete_task':[p['benchmark']['agent_cpu_ms_per_complete_task'] for p in parent],
                          'provider_calls':sum(p['benchmark']['provider_calls'] for p in parent),
                          'continuation_provider_calls':sum(r['continuation_provider_calls'] for r in samples),
                          'agent_after':[p['benchmark']['agent_after'] for p in parent],
                          'scope':parent[0]['benchmark']['scope']}
    result['watchdog_idle']=[p['idle_watchdog'] for p in parent]
    outbox=[json.loads(p.read_text()) for p in sorted((root/'reply-outbox').glob('trial-*.json')) if not p.name.endswith('process.json')]
    assert len(outbox)==3 and all(r['retained_rows']==256 and r['payload_bytes']==4096 for r in outbox)
    result['reply_outbox']={'trials':3,'retained_rows':256,'payload_bytes':4096,
        'phases_us':{phase:q([s for row in outbox for s in row[phase]['samples_us']]) for phase in ['enqueue','prepare_send','acknowledge','full_pending_page','empty_pending_page']},
        'cpu_us':[r['cpu'] for r in outbox],'wall_us':[r['wall_us'] for r in outbox],'peak_rss_kib':[r['peak_rss_kib'] for r in outbox],
        'scope':'Frozen component executable with private SQLite FULL synchronous durable receipts; pending full-page samples return 32 complete rows. Not an end-to-end latency or comparison to the older notification path.'}
    result['component_process_observations']=[json.loads(p.read_text()) for p in sorted(root.glob('*/*.process.json'))]
    (root/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ['identities','host_groups','host_idle','component_process_observations','watchdog_idle']},ensure_ascii=False,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)
