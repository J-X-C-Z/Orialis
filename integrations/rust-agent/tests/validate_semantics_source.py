#!/usr/bin/env python3
"""Verify all default targets and strict Clippy against unchanged runtime sources."""
import argparse, hashlib, importlib.util, json, os, platform, re, shutil, subprocess, time
from pathlib import Path
CRATE=Path(__file__).resolve().parents[1]
ROOT=CRATE.parent
spec=importlib.util.spec_from_file_location('freeze',ROOT/'freeze_host_runtime_release.py')
freeze=importlib.util.module_from_spec(spec);spec.loader.exec_module(freeze)

def main(out):
    out=out.resolve();out.mkdir(parents=True,exist_ok=False)
    before=freeze.sources()
    env=dict(os.environ,CARGO_INCREMENTAL='0')
    local=ROOT/'.toolchain/cargo/bin'
    if (local/'cargo').exists():
        env.update(CARGO_HOME=str(ROOT/'.toolchain/cargo'),RUSTUP_HOME=str(ROOT/'.toolchain/rustup'))
        env['PATH']=str(local)+os.pathsep+env['PATH']
    cargo=shutil.which('cargo',path=env['PATH']);assert cargo
    def capture(cmd):return subprocess.check_output(cmd,text=True,env=env,cwd=ROOT).strip()
    environment={'platform':platform.platform(),'machine':platform.machine(),'python':platform.python_version(),
                 'cargo':capture([cargo,'--version']),'rustc':capture([str(local/'rustc') if (local/'rustc').exists() else 'rustc','--version']),
                 'logical_cpus':os.cpu_count(),'notes':'Shared executor, no exclusive CPU allocation or imposed 2c1g target. No paid model, production credentials, deployment, real browser sandbox bypass or denied IPC retry.'}
    for name,path in [('cpu_max','/sys/fs/cgroup/cpu.max'),('memory_max','/sys/fs/cgroup/memory.max')]:
        try:environment[name]=Path(path).read_text().strip()
        except OSError as e:environment[name]={'unavailable':str(e)}
    (out/'environment.json').write_text(json.dumps(environment,indent=2))
    (out/'source-before.json').write_text(json.dumps(before,indent=2))
    runs=[]
    for name,args in [('all-targets',['test','--offline','--locked','--all-targets','--','--test-threads=1']),
                      ('clippy',['clippy','--offline','--locked','--all-targets','--','-D','warnings'])]:
        began=time.monotonic()
        with (out/(name+'.log')).open('w') as log:
            result=subprocess.run([cargo,*args],env=env,cwd=CRATE,stdout=log,stderr=subprocess.STDOUT)
        runs.append({'name':name,'command':[cargo,*args],'exit_code':result.returncode,'elapsed_s':time.monotonic()-began})
        (out/'runs.json').write_text(json.dumps(runs,indent=2))
        assert result.returncode==0,(name,'see log')
    after=freeze.sources()
    (out/'source-after.json').write_text(json.dumps(after,indent=2))
    assert before==after,'Runtime changed during validation; do not label stable'
    matches=re.findall(r'test result: (\w+)\. (\d+) passed; (\d+) failed; (\d+) ignored;', (out/'all-targets.log').read_text())
    assert matches and all(v[0]=='ok' and int(v[2])==0 for v in matches)
    result={'complete':True,'runtime_sources_unchanged':True,'source_tree_sha256':hashlib.sha256(json.dumps(before,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
            'targets':len(matches),'passed':sum(int(v[1]) for v in matches),'failed':0,'ignored':sum(int(v[3]) for v in matches),'clippy_passed':True,
            'limitations':'Default test set only; ignored benchmarks/real-system cases are not automatically passing. Coverage overlaps frozen and main test suites; do not sum all counts.','runs':runs}
    (out/'aggregate-checks.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);main(p.parse_args().out)
