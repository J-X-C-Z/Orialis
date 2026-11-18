#!/usr/bin/env python3
"""Run hash-bound release component and existing-host comparisons, without builds.
The caller must arrange the project quiet window; shared host isolation is not implied.
"""
import argparse, hashlib, json, os, subprocess, sys, time
from pathlib import Path
HERE=Path(__file__).resolve().parent

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def records(path):
 out=[]
 for line in path.read_text().splitlines():
  start=line.find('{');end=line.rfind('}')
  if start>=0 and end>start:
   try:out.append(json.loads(line[start:end+1]))
   except ValueError:pass
 return out

def run(command,out,env=None,timeout=300):
 out.parent.mkdir(parents=True,exist_ok=True);start=time.monotonic();observed=[]
 with out.open('w') as log:
  p=subprocess.Popen([str(v) for v in command],stdout=log,stderr=subprocess.STDOUT,env=env)
  while True:
   try:
    status=Path(f'/proc/{p.pid}/status').read_text()
    sample={line.split(':',1)[0]:int(line.split()[1])*1024 for line in status.splitlines() if line.startswith(('VmRSS:','VmHWM:'))}
    if sample:observed.append(sample)
   except (FileNotFoundError,ProcessLookupError):pass
   pid,state,usage=os.wait4(p.pid,os.WNOHANG)
   if pid:
    p.returncode=os.waitstatus_to_exitcode(state);break
   if time.monotonic()-start>timeout:
    p.kill();pid,state,usage=os.wait4(p.pid,0);p.returncode=os.waitstatus_to_exitcode(state);raise TimeoutError(str(command))
   time.sleep(.005)
 r={'command':[str(v) for v in command],'exit_code':p.returncode,'wall_seconds':time.monotonic()-start,'own_and_reaped_child_cpu_seconds':usage.ru_utime+usage.ru_stime,'observed_self_vmhwm_bytes':max((v.get('VmHWM',0) for v in observed),default=None),'observed_self_rss_bytes':max((v.get('VmRSS',0) for v in observed),default=None),'samples':len(observed),'memory_note':'5ms /proc sampling of this executable only, excludes descendants and may miss short peaks. No inherited ru_maxrss used.'}
 out.with_suffix('.process.json').write_text(json.dumps(r,indent=2))
 if p.returncode:raise RuntimeError(f'{out}: exit{p.returncode}')
 return r

def main(a):
 a.out.mkdir(parents=True,exist_ok=False);release=a.release.resolve();manifest=json.loads((release/'manifest.json').read_text())
 tests={row['target']:release/row['path'] for row in manifest['performance_test_binaries']}
 paths={'candidate':release/'orialis_agent','baseline':a.baseline.resolve(),'server':a.server.resolve(),'background_server':(a.background_server or a.server).resolve(),'driver':Path(__file__).resolve(),'host_driver':HERE/'compare_final_host.py','background_main':HERE/'e2e_background_delegation_main.py','file_python':HERE.parent/'scripts/benchmark_file_read.py'}
 paths.update({key:tests[key] for key in ['local_v4a','local_file_read_search','delegation_background']})
 identities={k:{'path':str(v),'sha256':sha(v)} for k,v in paths.items()}
 assert identities['candidate']['sha256']==manifest['binary_sha256']
 def unchanged():
  for k,v in identities.items():assert sha(v['path'])==v['sha256'],k
 unchanged();(a.out/'identities.json').write_text(json.dumps(identities,indent=2))
 runs=[]
 command=[sys.executable,paths['host_driver'],'--baseline',paths['baseline'],'--candidate',paths['candidate'],'--server',paths['server'],'--out',a.out/'host','--pairs','4','--iterations','60','--delays','0','20']
 runs.append(run(command,a.out/'host.log',timeout=900));unchanged();print('Existing host AB/BA complete',flush=True)
 for pair in range(4):
  order=['inline','background'] if pair%2==0 else ['background','inline']
  for mode in order:
   env=dict(os.environ,DELEGATION_BENCH_MODE=mode)
   path=a.out/'delegation'/f'pair-{pair+1}-{mode}.log'
   runs.append(run([tests['delegation_background'],'--ignored','--exact','measure_background_delegation_overhead','--nocapture'],path,env))
   values=[r for r in records(path) if r.get('schema_version')==2];assert len(values)==1,values
   path.with_suffix('.json').write_text(json.dumps(values[0],indent=2));unchanged()
 print('Detached/inline component AB/BA complete',flush=True)
 for trial in range(4):
  cases=['read_text','read_docx','read_notebook','search'];cases=cases if trial%2==0 else list(reversed(cases))
  for case in cases:
   path=a.out/'files'/f'trial-{trial+1}-{case}.log'
   runs.append(run([tests['local_file_read_search'],'--ignored','--exact','benchmark_local_read_search','--nocapture'],path,dict(os.environ,FILE_BENCH_CASE=case)))
   values=[r for r in records(path) if r.get('runtime')=='rust'];assert len(values)==1
   path.with_suffix('.json').write_text(json.dumps(values[0],indent=2));unchanged()
  for case in ['read_docx','read_notebook']:
   path=a.out/'files'/f'trial-{trial+1}-python-{case}.log';runs.append(run([sys.executable,paths['file_python'],'--case',case],path))
   values=[r for r in records(path) if r.get('runtime')=='python_upstream'];assert len(values)==1
   path.with_suffix('.json').write_text(json.dumps(values[0],indent=2));unchanged()
 print('Read/extraction/search measurements complete',flush=True)
 for trial in range(3):
  path=a.out/'v4a'/f'trial-{trial+1}.log';runs.append(run([tests['local_v4a'],'--ignored','--exact','benchmark_durable_transactions','--nocapture'],path,timeout=300))
  values=[r for r in records(path) if r.get('benchmark')=='native_v4a_durable_transaction'];assert len(values)==120,len(values)
  path.with_suffix('.json').write_text(json.dumps(values,indent=2));unchanged()
 print('Durable multi-file transaction measurements complete',flush=True)
 for trial in range(3):
  path=a.out/'background-main'/f'trial-{trial+1}.log';out=path.with_suffix('.json')
  runs.append(run([sys.executable,paths['background_main'],'--binary',paths['candidate'],'--server',paths['background_server'],'--out',out,'--benchmark-iterations','20'],path,timeout=180))
  value=json.loads(out.read_text());assert value['binary_sha256']==identities['candidate']['sha256'];assert value['benchmark']['iterations']==20;unchanged()
 print('Main background notifications measured',flush=True)
 unchanged();(a.out/'runs.json').write_text(json.dumps(runs,indent=2));(a.out/'complete.json').write_text(json.dumps({'complete':True,'all_identities_unchanged':True,'identities':identities,'limitations':['Shared executor with project quiet window, not CPU isolation.','Base/full existing-host matrix excludes newly opt-in background/browser/profile runtime.','Component test-binary memory is not the main Agent.','Python extraction reference excludes Rust confinement/pagination, so not a speedup comparison.','V4A has no equivalent prior durable multi-file baseline; measures actual native durability costs.','Legacy Server background notification ACK is not persisted chat history.']},indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--release',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--server',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--background-server',type=Path);main(p.parse_args())
