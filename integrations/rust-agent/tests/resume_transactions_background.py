#!/usr/bin/env python3
"""Resume only unmeasured background phase after optional /proc observation fix.
Historical first-attempt inputs and logs are retained; prior valid phases never rerun.
"""
import argparse,hashlib,json,sys
from pathlib import Path
from benchmark_transactions_release import run,sha

def main(root):
 identities=json.loads((root/'identities.json').read_text());first=dict(identities)
 for key,row in identities.items():
  if key!='background_main':assert sha(row['path'])==row['sha256'],key
 assert sha(root/'failed-background-attempt/e2e_background_delegation_main.py')==first['background_main']['sha256']
 host=json.loads((root/'host/comparison.json').read_text());assert host['completed'] and host['all_hashes_unchanged']
 assert len(list((root/'delegation').glob('pair-*.log')))==8
 assert len(list((root/'files').glob('trial-*.log')))==24
 assert len(list((root/'v4a').glob('trial-*.log')))==3
 identities['background_main']={'path':first['background_main']['path'],'sha256':sha(first['background_main']['path'])}
 (root/'resumed-identities.json').write_text(json.dumps(identities,indent=2))
 runs=[]
 for trial in range(3):
  path=root/'background-main'/f'trial-{trial+1}.log';assert not path.exists()
  out=path.with_suffix('.json')
  runs.append(run([sys.executable,identities['background_main']['path'],'--binary',identities['candidate']['path'],'--server',identities['background_server']['path'],'--out',out,'--benchmark-iterations','20'],path,timeout=180))
  value=json.loads(out.read_text());assert value['passed']==11 and value['binary_sha256']==identities['candidate']['sha256'] and value['server_sha256']==identities['background_server']['sha256'];assert value['benchmark']['iterations']==20
  for key,row in identities.items():assert sha(row['path'])==row['sha256'],key
  print('Background trial',trial+1,'passed',flush=True)
 all_runs=[json.loads(p.read_text()) for p in root.rglob('*.process.json') if 'failed-background-attempt' not in p.parts]
 (root/'runs.json').write_text(json.dumps(all_runs,indent=2))
 result={'complete':True,'all_identities_unchanged':False,'all_runtime_identities_unchanged':True,'measurement_stages_verified':True,'identities':identities,'initial_identities_file':'identities.json','resume_driver_sha256':sha(Path(__file__)),'fixture_correction':'Initial background attempt completed correctness but failed before any timed benchmark sample: optional /proc/PID/task/PID/children was unavailable. Missing child-tree observation now records null and error, without claiming child-tree memory/CPU. Only this unmeasured phase resumed; runtime code/binaries and all completed measurements unchanged. Initial script and failure retained.','limitations':['Shared executor with project quiet window, not CPU isolation.','Base/full existing-host matrix excludes newly opt-in background/browser/profile runtime.','Component test-binary memory is not the main Agent.','Python extraction reference excludes Rust confinement/pagination, so not a speedup comparison.','V4A has no equivalent prior durable multi-file baseline; measures actual native durability costs.','Legacy Server background notification ACK is not persisted chat history.','Main background CPU/memory is own Agent; /proc child enumeration unavailable and explicitly recorded.']}
 (root/'complete.json').write_text(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)
