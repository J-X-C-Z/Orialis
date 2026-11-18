#!/usr/bin/env python3
"""Direct A/B of original and actually compiled patched Orialis servers.
No LD_PRELOAD, proxy, or socket-option injection is used in this verification.
Frozen Agent, controlled model and stage measurements are reused unchanged.
"""
import argparse
import asyncio
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess

from probe_transport_latency import run_case, percentile, ROOT


async def main(args):
    assert not os.environ.get("LD_PRELOAD"),"A/B must run without LD_PRELOAD"
    assert not os.environ.get("ORIALIS_TEST_WS_NODELAY"),"A/B must run without socket injection"
    args.out.mkdir(parents=True,exist_ok=True)
    rows=[]
    hashes={"agent":hashlib.sha256(args.binary.read_bytes()).hexdigest(),"original_server":hashlib.sha256(args.original_server.read_bytes()).hexdigest(),"patched_server":hashlib.sha256(args.patched_server.read_bytes()).hexdigest()}
    assert hashes["original_server"]!=hashes["patched_server"],"patched server binary must be distinct"
    for trial in range(args.trials):
        for variant in (["original","patched"] if trial%2==0 else ["patched","original"]):
            child=copy.copy(args);child.server_binary=args.original_server if variant=="original" else args.patched_server
            result=await run_case(child,{"name":f"{variant}-trial-{trial+1}","model":"aiohttp_default","variant":"rust","server_build":variant},None)
            rows.append(result)
    summary=[]
    for variant in ["original","patched"]:
        group=[r for r in rows if r["case"]["server_build"]==variant];samples=[row for g in group for row in g["rows"]]
        summary.append({"server":variant,"requests":len(samples),"failures":0,"phases_ms":{key:{"p50":percentile([s["phases"][key] for s in samples],.5),"p95":percentile([s["phases"][key] for s in samples],.95),"p99":percentile([s["phases"][key] for s in samples],.99)} for key in samples[0]["phases"]},"model_socket_nodelay":sorted({value for g in group for value in g["model_socket_nodelay"]})})
    report={"scope":"Actual independently compiled TCP_NODELAY server patch versus untouched original server; same frozen Rust Agent; direct sockets, no LD_PRELOAD/proxy/shim; synthetic model only","sha256":hashes,"base_source_sha":"f9a064bf05b18265afd26905e7240777d4ce355c","trials":args.trials,"iterations_per_variant_per_trial":args.iterations,"model_delay_ms":args.model_delay_ms,"summary":summary,"baseline_server_tracked_diff":subprocess.check_output(["git","-C",str(ROOT/"orialis"),"diff","--","orialis-server"],text=True),"limitations":["Shared unpinned executor; small local controlled sample, not production throughput or WAN evidence.","SQLite visibility is bounded by polling, not exact internal commit timing.","Compiled patch enables TCP_NODELAY for every accepted connection, unlike earlier WS-only shim.","This is a generic server transport optimization, not a Rust Agent language/algorithm gain."]}
    (args.out/"summary.json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))


if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,default=ROOT/"hermes-rust-core/results/stream-release/orialis_agent");p.add_argument("--original-server",type=Path,default=ROOT/"orialis/target/release/orialis-server");p.add_argument("--patched-server",type=Path,default=ROOT/"orialis-tcp-nodelay/target/release/orialis-server");p.add_argument("--out",type=Path,default=ROOT/"hermes-rust-core/results/server-nodelay-compiled-ab");p.add_argument("--iterations",type=int,default=20);p.add_argument("--trials",type=int,default=2);p.add_argument("--model-delay-ms",type=float,default=5);a=p.parse_args();asyncio.run(main(a))
