#!/usr/bin/env python3
"""AB/BA background notification transport comparison, same frozen Agent/fixture."""
import argparse,json,sys
from pathlib import Path
from benchmark_transactions_release import run,sha
from summarize_transactions_performance import quantiles

def main(a):
 a.out.mkdir(parents=True,exist_ok=False);script=Path(__file__).parent/'e2e_background_delegation_main.py'
 paths={'agent':a.agent.resolve(),'baseline':a.baseline.resolve(),'candidate':a.candidate.resolve(),'fixture':script.resolve(),'driver':Path(__file__).resolve()}
 identities={k:{'path':str(v),'sha256':sha(v)} for k,v in paths.items()};(a.out/'identities.json').write_text(json.dumps(identities,indent=2))
 groups={'baseline':[],'candidate':[]};runs=[]
 for pair in range(4):
  for mode in (['baseline','candidate'] if pair%2==0 else ['candidate','baseline']):
   for k,v in paths.items():assert sha(v)==identities[k]['sha256']
   log=a.out/f'pair-{pair+1}-{mode}.log';out=log.with_suffix('.json')
   runs.append(run([sys.executable,script,'--binary',paths['agent'],'--server',paths[mode],'--out',out,'--benchmark-iterations','20'],log,timeout=180))
   r=json.loads(out.read_text());assert r['passed']==11 and r['binary_sha256']==identities['agent']['sha256'] and r['server_sha256']==identities[mode]['sha256'];groups[mode].append(r['benchmark']);print(pair+1,mode,'passed',flush=True)
 for k,v in paths.items():assert sha(v)==identities[k]['sha256']
 summaries={}
 for mode,rows in groups.items():
  samples=[s for r in rows for s in r['raw_samples']]
  summaries[mode]={'tasks':len(samples),'parent_final_ms':quantiles([s['parent_final_ms'] for s in samples]),'notification_ms':quantiles([s['child_release_to_mobile_notification_ms'] for s in samples]),'mean_agent_cpu_ms_per_task':sum(r['agent_cpu_ms_per_complete_task'] for r in rows)/len(rows),'provider_calls':sum(r['provider_calls'] for r in rows),'agent_memory_after':[r['agent_snapshots']['after']['memory'] for r in rows]}
 result={'complete':True,'all_hashes_unchanged':True,'identities':identities,'groups':summaries,'scope':'Four fresh-process AB/BA pairs, 20 warm tasks each. Baseline original Server; candidate combined control/ledger/TCP_NODELAY patch. Same actual Agent and controlled provider fixture. Not an isolated single-option TCP experiment, no real WAN/mobile renderer. Parent latency includes REST polling; notification latency uses exact protocol observer timestamp. Main Agent own CPU and memory only.'}
 (a.out/'summary.json').write_text(json.dumps(result,indent=2));(a.out/'runs.json').write_text(json.dumps(runs,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser()
 for k in ['agent','baseline','candidate','out']:p.add_argument('--'+k,type=Path,required=True)
 main(p.parse_args())
