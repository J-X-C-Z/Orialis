#!/usr/bin/env python3
"""Run frozen release test executables sequentially; never build during sampling."""
import argparse,hashlib,json,subprocess,time
from pathlib import Path

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(a):
 a.release=a.release.resolve();a.out=a.out.resolve();a.out.mkdir(parents=True,exist_ok=False)
 manifest=json.loads((a.release/'manifest.json').read_text());hashes={v['path']:v['sha256'] for v in manifest['performance_test_binaries']}
 cases=[('persistent_python-tests','measure_cold_warm_cells'),('delegation-tests','measure_delegation_overhead'),('hermes_rust_core-tests','delegation::output_schema::benchmarks::measure_schema_compile_and_validation'),('hermes_rust_core-tests','tool_images::tests::profile_native_image_stages'),('tool_images-tests','profile_native_vs_auxiliary_http')]
 rows=[]
 for file,name in cases:
  binary=a.release/file;assert sha(binary)==hashes[file]
  destination=a.out/name.rsplit('::',1)[-1];destination.mkdir();started=time.monotonic()
  command=[str(binary),name,'--ignored','--exact','--test-threads=1','--nocapture'];print('START',name,flush=True)
  with (destination/'run.log').open('w') as log:
   try:code=subprocess.run(command,cwd=destination,stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
   except subprocess.TimeoutExpired:code='timeout'
  rows.append({'test':name,'command':command,'binary_sha256':hashes[file],'exit_code':code,'seconds':time.monotonic()-started})
  assert sha(binary)==hashes[file]
  (a.out/'index.json').write_text(json.dumps({'runtime_binary_sha256':manifest['binary_sha256'],'source_tree_sha256':manifest['source_tree_sha256'],'runs':rows,'scope':'Component release binaries from the same frozen source, not main-process end-to-end latency. Shared executor; caller schedules a quiet window. See raw logs for unavailable metrics and fixture limits.'},indent=2))
  print('END',name,code,flush=True)
 assert all(v['exit_code']==0 for v in rows),rows
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--release',type=Path,required=True);p.add_argument('--out',type=Path,required=True);main(p.parse_args())
