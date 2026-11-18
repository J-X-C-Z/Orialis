#!/usr/bin/env python3
"""Sequential current-release true Server tests. All child services are disposable.
Do not confuse an intermediate per-module result with this hash-bound run.
"""
import argparse,hashlib,json,shutil,subprocess,sys,time
from pathlib import Path

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(a):
 a.out.mkdir(parents=True,exist_ok=False)
 frozen=a.out/'orialis_agent';shutil.copy2(a.binary.resolve(),frozen);frozen=frozen.resolve()
 binary_hash=digest(frozen);server=a.server.resolve();server_hash=digest(server)
 companions={}
 for name,source in [('profile_sync',a.sync_binary),('profile_coordinator',a.coordinator_binary)]:
  if source:
   target=(a.out/name).resolve();shutil.copy2(source.resolve(),target)
   companions[name]={'path':str(target),'sha256':digest(target)}
 tests=['e2e_workspace','e2e_interactions_main','e2e_full_lifecycle','e2e_updates_main','e2e_scheduler_main','e2e_local_main','e2e_documents_memory_main','e2e_session_controls_main','e2e_vision_main','e2e_python_main','e2e_native_images_main','e2e_delegation_main','e2e_stream_events']
 if companions:tests.append('e2e_profile_main')
 if a.with_offline_tools:tests += ['e2e_local_increment_main','e2e_browser_main']
 if a.with_transactions:tests += ['e2e_v4a_main','e2e_file_read_search_main','e2e_background_delegation_main']
 if a.with_semantics:tests += ['e2e_file_skills_semantics_main','e2e_parent_continuation_main']
 result={'binary_sha256':binary_hash,'server_sha256':server_hash,'companion_binaries':companions,'tests':[],'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'limitations':'Synthetic isolated users/models, true original Server and current Agent. Profile sync, if included, uses local logical devices/hub. Not production, remote SSH, live model quality, mobile Flutter renderer, WAN or real provider-account evaluation.'}
 for name in tests:
  output=(a.out/(name+'.json')).resolve();log=a.out/(name+'.log')
  script=Path(__file__).parent/(name+'.py')
  command=[sys.executable,str(script),'--binary',str(frozen),'--server-binary' if name=='e2e_stream_events' else '--server',str(server),'--out',str(output)]
  if name=='e2e_profile_main':
   command+=['--sync-binary',companions['profile_sync']['path'],'--coordinator-binary',companions['profile_coordinator']['path']]
  began=time.monotonic()
  with log.open('w') as f:run=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=300 if name=='e2e_parent_continuation_main' else 180)
  entry={'test':name,'exit_code':run.returncode,'elapsed_s':time.monotonic()-began,'log':log.name,'script_sha256':digest(script)}
  if output.exists():
   data=json.loads(output.read_text());entry['checks_passed']=data.get('passed',data.get('checks_passed'));entry['result']=output.name
   assert data.get('binary_sha256',data.get('agent_binary_sha256'))==binary_hash,(name,'wrong Agent version')
   assert data.get('server_sha256',data.get('server_binary_sha256'))==server_hash,(name,'wrong Server version')
   if name=='e2e_profile_main':
    assert data.get('sync_binary_sha256')==companions['profile_sync']['sha256'],(name,'wrong sync version')
    assert data.get('coordinator_binary_sha256')==companions['profile_coordinator']['sha256'],(name,'wrong coordinator version')
  result['tests'].append(entry);(a.out/'summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
  print(json.dumps(entry),flush=True)
  if run.returncode:raise SystemExit('Validation failed; see '+str(log))
 assert digest(frozen)==binary_hash and digest(server)==server_hash
 for companion in companions.values():assert digest(Path(companion['path']))==companion['sha256']
 result['completed_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime());result['passed_scripts']=len(result['tests']);result['checks_passed']=sum(e.get('checks_passed',0) or 0 for e in result['tests'])
 (a.out/'summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False));print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--server',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--sync-binary',type=Path);p.add_argument('--coordinator-binary',type=Path)
 p.add_argument('--with-offline-tools',action='store_true')
 p.add_argument('--with-transactions',action='store_true')
 p.add_argument('--with-semantics',action='store_true')
 a=p.parse_args()
 if bool(a.sync_binary)!=bool(a.coordinator_binary):p.error('provide both --sync-binary and --coordinator-binary, or neither')
 main(a)
