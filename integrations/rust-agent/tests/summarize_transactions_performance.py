#!/usr/bin/env python3
import argparse,json,math,statistics,collections
from pathlib import Path

def quantiles(xs):
 xs=sorted(xs);assert xs
 return {'count':len(xs),'p50':xs[math.ceil(.5*len(xs))-1],'p95':xs[math.ceil(.95*len(xs))-1],'p99':xs[math.ceil(.99*len(xs))-1],'mean':statistics.mean(xs)}
def main(root):
 done=json.loads((root/'complete.json').read_text());assert done['complete'] and (done['all_identities_unchanged'] or (done.get('all_runtime_identities_unchanged') and done.get('measurement_stages_verified')))
 host=json.loads((root/'host/comparison.json').read_text());assert host['completed']
 result={'identities':done['identities'],'host_groups':host['groups'],'limitations':done['limitations'],'measurement_provenance':{k:v for k,v in done.items() if k!='identities'},'quantiles':'Nearest-rank pooled individual observations; independent repetitions remain in raw files. No statistical CI or causal speedup claim.'}
 result['host_requests']=sum(v[k]['requests'] for g in host['groups'] for v in g['summary'] for k in ('baseline','candidate'));assert result['host_requests']==3840
 result['host_failures']=sum(v[k]['failures'] for g in host['groups'] for v in g['summary'] for k in ('baseline','candidate'));assert result['host_failures']==0
 actors=collections.defaultdict(list)
 for g in host['groups']:
  for a in g['actors']:actors[(a['implementation'],a['profile'])].append(a)
 result['host_idle']=[{'implementation':k[0],'profile':k[1],'observations':len(rows),**{field:quantiles([r[field] for r in rows]) for field in ['warm_rss_bytes','private_dirty_bytes','idle_cpu_ms','startup_online_ms','threads','fds']}} for k,rows in sorted(actors.items())]
 result['delegation']=[]
 for mode in ('inline','background'):
  rows=[json.loads(p.read_text()) for p in sorted((root/'delegation').glob(f'pair-*-{mode}.json')) if not p.name.endswith('process.json')];assert len(rows)==4
  samples=[s for r in rows for s in r['raw_samples_in_request_order']];assert len(samples)==400
  result['delegation'].append({'mode':mode,'runs':len(samples),'latency_us':{k:quantiles([s[k] for s in samples]) for k in ['dispatch_return_us','completion_observed_us','durable_handoff_us']},'mean_cpu_ms_per_task':sum(r['phase_cpu_ns'] for r in rows)/len(samples)/1e6,'phase_wall_seconds':sum(r['phase_wall_ns'] for r in rows)/1e9,'memory_after_phase':[r['memory_after_phase'] for r in rows],'database_bytes':[r['database_bytes_before_teardown'] for r in rows],'scope':rows[0]['phase_scope']})
 files=collections.defaultdict(list)
 for p in (root/'files').glob('trial-*.json'):
  if p.name.endswith('process.json'):continue
  r=json.loads(p.read_text());files[(r['runtime'],r['case'])].append(r)
 result['files']=[]
 for (runtime,case),rows in sorted(files.items()):
  assert len(rows)==4;samples=[v for r in rows for v in r['elapsed_ns']];assert len(samples)==800
  result['files'].append({'runtime':runtime,'case':case,'latency_ms':quantiles([x/1e6 for x in samples]),'mean_cpu_ms_per_op':sum(r['cpu_seconds'] for r in rows)*1000/len(samples),'max_own_hwm_mib':max(r['max_rss_kib'] for r in rows)/1024,'scope':rows[0]['scope']})
 tx=collections.defaultdict(list)
 for p in (root/'v4a').glob('trial-*.json'):
  if p.name.endswith('process.json'):continue
  for r in json.loads(p.read_text()):tx[(r['files'],r['file_bytes'])].append(r)
 result['v4a']=[]
 for (files,size),rows in sorted(tx.items()):
  assert len(rows)==90
  result['v4a'].append({'files':files,'bytes_per_file':size,'latency_ms':quantiles([r['elapsed_ns']/1e6 for r in rows]),'cpu_ms':quantiles([r['cpu_ns']/1e6 for r in rows]),'includes':rows[0]['includes'],'excludes':rows[0]['excludes']})
 rows=[json.loads(p.read_text())['benchmark'] for p in sorted((root/'background-main').glob('trial-*.json')) if not p.name.endswith('process.json')];assert len(rows)==3
 samples=[s for r in rows for s in r['raw_samples']];assert len(samples)==60
 result['background_main']={'tasks':60,'parent_final_ms':quantiles([s['parent_final_ms'] for s in samples]),'notification_after_child_release_ms':quantiles([s['child_release_to_mobile_notification_ms'] for s in samples]),'agent_cpu_ms_per_complete_task':statistics.mean(r['agent_cpu_ms_per_complete_task'] for r in rows),'agent_memory_after':[r['agent_snapshots']['after']['memory'] for r in rows],'provider_calls':sum(r['provider_calls'] for r in rows),'scope':rows[0]['scope']}
 (root/'summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False));print(json.dumps({k:v for k,v in result.items() if k not in ['host_groups','identities','host_idle']},indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)
