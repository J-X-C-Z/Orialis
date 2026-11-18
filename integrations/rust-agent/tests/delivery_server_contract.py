#!/usr/bin/env python3
"""Actual Rust delivery module -> fixed release Orialis server, no fake ACKs.
All cooperating processes start in this invocation. Records the legacy ACK-only
boundary honestly: the pinned extension handler does not persist message rows.
"""
import argparse, asyncio, hashlib, importlib.util, json, os
from pathlib import Path
import socket, sqlite3, subprocess, tempfile, time, urllib.request
import websockets
ROOT=Path(__file__).resolve().parents[2]
SHA="f9a064bf05b18265afd26905e7240777d4ce355c"

def api(base,method,path,body=None):
    req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={"Content-Type":"application/json","x-orialis-device-id":"delivery-fixture-owner"})
    with urllib.request.urlopen(req,timeout=3) as response:return json.load(response)

async def main(args):
    assert subprocess.check_output(["git","-C",str(ROOT/"orialis"),"rev-parse","HEAD"],text=True).strip()==SHA
    spec=importlib.util.spec_from_file_location("original_protocol",ROOT/"orialis/integrations/hermes/orialis/protocol.py")
    original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
    with tempfile.TemporaryDirectory(prefix="delivery-real-contract-") as temp:
        directory=Path(temp)
        with socket.socket() as sock:sock.bind(("127.0.0.1",0));port=sock.getsockname()[1]
        base=f"http://127.0.0.1:{port}";url=base.replace("http://","ws://")+"/api/v1/agent/ws"
        env=dict(os.environ,ORIALIS_ENV="development",ORIALIS_HOST="127.0.0.1",ORIALIS_PORT=str(port),ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH="1",ORIALIS_DATABASE_URL=f"sqlite://{directory}/server.sqlite?mode=rwc",ORIALIS_UPLOAD_DIR=str(directory/"uploads"),ORIALIS_AGENT_DEVICE_TOKEN="synthetic-delivery-test-token",CARGO_HOME=str(ROOT/".toolchain/cargo"),RUSTUP_HOME=str(ROOT/".toolchain/rustup"),DELIVERY_TEST_SERVER=url,DELIVERY_TEST_FRAMES=str(directory/"frames.json"))
        env["PATH"]=str(ROOT/".toolchain/cargo/bin")+os.pathsep+env["PATH"]
        with (directory/"server.log").open("w+") as log:
            server=subprocess.Popen([str(args.server_binary.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT)
            try:
                start=time.monotonic()
                while True:
                    try:await asyncio.to_thread(api,base,"GET","/api/v1/health");break
                    except OSError:
                        if time.monotonic()-start>15:raise
                        if server.poll() is not None:raise RuntimeError("real server exited")
                        await asyncio.sleep(.03)
                await asyncio.to_thread(api,base,"GET","/api/v1/conversations")
                await asyncio.to_thread(api,base,"POST","/api/v1/conversations",{"id":"delivery-conversation","title":"Synthetic delivery contract"})
                command=["cargo","test","--manifest-path",str(ROOT/"hermes-rust-core/Cargo.toml"),"--test","scheduler_delivery","real_server_delivery_fixture","--","--exact","--ignored","--nocapture"]
                process=await asyncio.create_subprocess_exec(*command,env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.STDOUT)
                stdout,_=await process.communicate();assert process.returncode==0,stdout.decode()
                frames=json.loads((directory/"frames.json").read_text())
                for frame in frames:assert original.parse_message(original.encode(frame))==frame
                assert {frame["type"] for frame in frames}=={"cron.delivery","proactive.delivery","delivery.send"}
                stored=sqlite3.connect(directory/"server.sqlite").execute("SELECT COUNT(*) FROM messages WHERE id LIKE 'real-delivery-%'").fetchone()[0]
                assert stored==0,"fixed-server contract changed: now durable; update capability/receipt semantics"
                # Original server accepts replay with received again; it has no
                # persistent delivery-ID dedupe. Do not label it exactly-once.
                async with websockets.connect(url,additional_headers={"Authorization":"Bearer synthetic-delivery-test-token"}) as ws:
                    await ws.send(original.encode(original.hello("TE_ST_Rust",platform="linux")))
                    assert json.loads(await ws.recv())["type"]=="hello_ack"
                    await ws.send(original.encode(frames[0]));ack=json.loads(await ws.recv())
                    assert ack["type"]=="delivery.ack" and ack["delivery_id"]==frames[0]["delivery_id"] and ack["status"]=="received"
                report={"scope":"Actual Rust module, original Python parser and real fixed release Orialis server; synthetic localhost data only","orialis_sha":SHA,"server_sha256":hashlib.sha256(args.server_binary.read_bytes()).hexdigest(),"checks_passed":5,"checks":["Rust standalone handshake and positive matching ACK for cron.delivery","Rust standalone handshake and positive matching ACK for proactive.delivery","Rust standalone handshake and positive matching ACK for delivery.send","All actual Rust frames accepted by original Python parser","Explicit legacy boundary: ACK received but zero message rows; same-ID replay returns received, not durable duplicate receipt"],"persisted_message_rows":stored,"frames":frames,"cargo_test_output":stdout.decode()}
                args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))
            finally:
                server.terminate()
                try:server.wait(timeout=5)
                except subprocess.TimeoutExpired:server.kill();server.wait()

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--server-binary",type=Path,default=ROOT/"orialis/target/release/orialis-server");p.add_argument("--out",type=Path,default=ROOT/"hermes-rust-core/results/delivery-server-contract.json");asyncio.run(main(p.parse_args()))
