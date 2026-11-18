#!/usr/bin/env python3
"""Run frozen test binaries without rebuilding or enabling prohibited fixtures."""
import argparse,hashlib,json,os,re,subprocess
from pathlib import Path

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(a):
 root=a.release.resolve();a.out.mkdir(parents=True,exist_ok=False)
 manifest=json.loads((root/'manifest.json').read_text());result={'binary_sha256':sha(root/'orialis_agent'),'suites':[]}
 assert result['binary_sha256']==manifest['binary_sha256']
 env=dict(os.environ,ORIALIS_REAL_SERVER_BIN=str(a.server.resolve()),ORIALIS_TEST_SERVER_BINARY=str(a.server.resolve()),ORIALIS_PROTOCOL_PY=str(a.protocol.resolve()))
 rows=manifest['performance_test_binaries']
 def run(name,binary,args):
  log=a.out/(name+'.log')
  with log.open('w') as f:p=subprocess.run([str(binary),*args],stdout=f,stderr=subprocess.STDOUT,env=env,timeout=300)
  matches=re.findall(r'test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored;',log.read_text())
  assert matches,(name,log)
  r={'name':name,'binary_sha256':sha(binary),'exit_code':p.returncode,'passed':sum(int(m[0]) for m in matches),'failed':sum(int(m[1]) for m in matches),'ignored':sum(int(m[2]) for m in matches)}
  result['suites'].append(r);(a.out/'summary.json').write_text(json.dumps(result,indent=2));print(json.dumps(r),flush=True)
  assert p.returncode==0,r
 for r in rows:
  binary=root/r['path'];assert sha(binary)==r['sha256'];run(r['target'],binary,['--test-threads=1']);assert sha(binary)==r['sha256']
 run('inbound_real',root/'inbound_delivery-tests',['--ignored','--test-threads=1'])
 result.update(passed=sum(r['passed'] for r in result['suites']),failed=sum(r['failed'] for r in result['suites']),overlapping_coverage_not_additive=True)
 assert sha(root/'orialis_agent')==result['binary_sha256']
 (a.out/'summary.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--release',type=Path,required=True);p.add_argument('--server',type=Path,required=True);p.add_argument('--protocol',type=Path,required=True);p.add_argument('--out',type=Path,required=True);main(p.parse_args())
