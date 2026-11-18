#!/usr/bin/env python3
"""Narrow original-component comparison, adapted without changing original harness.
Explicit frozen Rust/server paths; actual original Python components, not GatewayRunner.
Both model workloads use the unchanged existing deterministic model fixture.
Additional measurement: auxiliary/primary/vision calls and actual provider duration.
"""
import argparse,concurrent.futures,json,os,signal,socket,statistics,subprocess,sys,tempfile,threading,time,urllib.request,uuid
from pathlib import Path
import psutil
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"orialis-full-eval/harness"))
from client import Client
ROOT=Path(__file__).resolve().parents[2]
PYTHON=Path(os.environ.get('HERMES_PYTHON','/tmp/hermes-full-env/gen-875da7f9ccb44ec6abe72396905579c3/venv/bin/python'))

def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def http(base,path='/health',data=None):
    req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'},method='GET' if data is None else 'POST')
    with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
def wait_http(base,p,timeout=30,path="/health"):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if p.poll() is not None:raise RuntimeError('process exited before HTTP readiness')
        try:return http(base,path)
        except OSError:time.sleep(.05)
    raise TimeoutError(base)
def quantile(v,q):
    v=sorted(v);return v[min(len(v)-1,max(0,__import__('math').ceil(q*len(v))-1))]
class Meter:
    def __init__(self,pid):self.pid=pid;self.rows=[];self.stop=threading.Event();self.worker=threading.Thread(target=self.sample,daemon=True);self.worker.start()
    def snapshot(self):
        try:ps=[psutil.Process(self.pid)];ps+=ps[0].children(recursive=True)
        except psutil.Error:return {'rss_bytes':0,'cpu_seconds':0,'processes':0,'threads':0}
        rss=cpu=threads=0
        for p in ps:
            try:rss+=p.memory_info().rss;t=p.cpu_times();cpu+=t.user+t.system;threads+=p.num_threads()
            except psutil.Error:pass
        return {'rss_bytes':rss,'cpu_seconds':cpu,'processes':len(ps),'threads':threads}
    def sample(self):
        while not self.stop.is_set():self.rows.append({'elapsed':time.monotonic(),**self.snapshot()});self.stop.wait(.02)
    def close(self):self.stop.set();self.worker.join();return self.rows

def run_variant(args,variant,trial,delay):
    name=f'{trial:02}-{variant}-delay{delay}';out=args.out/name;out.mkdir(parents=True,exist_ok=True);logs=[];procs=[];meter=None;server_meter=None
    # Private temporary state prevents mixing test users, histories, and dedup IDs.
    with tempfile.TemporaryDirectory(prefix='orialis-eval-') as d:
      state=Path(d);sp,mp=port(),port();base=f'http://127.0.0.1:{sp}';model=f'http://127.0.0.1:{mp}';token='isolated-evaluation-token'
      def launch(cmd,env,label):
        log=(out/(label+'.log')).open('w');logs.append(log);p=subprocess.Popen([str(x) for x in cmd],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);procs.append(p);return p
      clean_env=os.environ.copy()
      for key in list(clean_env):
        if any(mark in key.upper() for mark in ('API_KEY','TOKEN','SECRET','PASSWORD')):clean_env.pop(key,None)
      env=clean_env.copy();env.update(ORIALIS_ENV='development',ORIALIS_HOST='127.0.0.1',ORIALIS_PORT=str(sp),ORIALIS_PUBLIC_URL=base,ORIALIS_DEV_DEVICE_AUTH='1',ORIALIS_DATABASE_URL=f'sqlite://{state}/server.sqlite?mode=rwc',ORIALIS_UPLOAD_DIR=str(state/'uploads'),ORIALIS_AGENT_DEVICE_TOKEN=token)
      server=launch([args.server_binary],env,'server');mock=launch([sys.executable,ROOT/'orialis-full-eval/harness/mock_model.py','--port',mp,'--delay-ms',delay],clean_env.copy(),'model')
      try:
        wait_http(base,server,path="/api/v1/health");wait_http(model,mock);client=Client(base);client.bootstrap();server_meter=Meter(server.pid)
        start=time.perf_counter()
        if variant=='rust':
            cmd=[args.rust_binary,'--server',base.replace('http://','ws://')+'/api/v1/agent/ws','--device','JXCZ_AOZORA_Hermes','--token',token,'--db',state/'rust.sqlite','--endpoint',model+'/v1/chat/completions','--model','bench-chat','--vision-model','bench-vision']
        else:
            cmd=[args.python_binary,ROOT/'orialis-full-eval/python_baseline/launch.py','--component-integration','--hermes',ROOT/'upstream-hermes','--orialis',ROOT/'orialis','--home',state/'hermes','--server',base.replace('http://','ws://')+'/api/v1/agent/ws','--device','JXCZ_AOZORA_Hermes','--token',token,'--model-base',model+'/v1','--model','bench-chat','--vision-model','bench-vision']
        gateway=launch(cmd,clean_env.copy(),'gateway');meter=Meter(gateway.pid);client.wait_agent(timeout=90);startup=(time.perf_counter()-start)*1000;time.sleep(.2)
        result={'variant':variant,'scope':'standalone Rust agent' if variant=='rust' else 'original Python OrialisAdapter + actual AIAgent + SessionDB component harness, NOT full GatewayRunner','trial':trial,'binary_sha256':__import__('hashlib').sha256((args.rust_binary).read_bytes()).hexdigest() if variant=='rust' else None,'server_variant':args.server_variant,'server_sha256':__import__('hashlib').sha256(args.server_binary.read_bytes()).hexdigest(),'model_delay_ms':delay,'startup_online_ms':startup,'idle':meter.snapshot(),'server_idle':server_meter.snapshot(),'workloads':{},'correctness':{},'commands':{'gateway':list(map(str,cmd)),'server':str(args.server_binary)}}
        # A real persisted reply is the readiness/semantic smoke test, never merely a WS hello.
        conversation=client.conversation();first=client.chat('BENCH_ID=smoke',conversation,poll=.002,timeout=70);assert 'ANSWER:smoke:' in first['response']['content'],first
        result['correctness']['chat_persisted']=True;result['first_turn_ms']=first['latency_ms']
        mem=client.memory('BENCH_ID=memory-smoke screenshot text',poll=.002,timeout=120);assert mem['response']['status']=='completed' and 'Bench memory' in mem['response']['content'],mem
        result['correctness']['screen_memory_persisted']=True
        if args.smoke:
            result['model_records']=http(model,'/metrics');(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));return result
        n=args.n
        def workload(label,count,concurrency,memory=False,warm=False,image=False):
            if warm:convs=[client.conversation()]*count
            elif not memory:convs=[client.conversation() for _ in range(count)]
            else:convs=[]
            model_before=http(model,'/metrics')['count'];before=meter.snapshot();server_before=server_meter.snapshot();sample_start=len(meter.rows);server_sample_start=len(server_meter.rows);start=time.perf_counter();rows=[]
            def task(i):
                marker=f'{label}-{i}'
                try:
                    if memory:
                        extra={'imageBase64':'/9j/AAH/2Q=='} if image else {}
                        r=client.memory(f'BENCH_ID={marker} Synthetic screen text.',poll=.002,timeout=120,**extra);assert r['response']['status']=='completed' and marker in r['response']['content'],r
                    else:
                        r=client.chat(f'BENCH_ID={marker} Answer this controlled question.',convs[i],poll=.002,timeout=70);assert f'ANSWER:{marker}:' in r['response']['content'],r
                    return {'index':i,'ok':True,'latency_ms':r['latency_ms']}
                except Exception as e:return {'index':i,'ok':False,'error':str(e)}
            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:rows=list(pool.map(task,range(count)))
            elapsed=time.perf_counter()-start;time.sleep(.1);after=meter.snapshot();records=http(model,'/metrics')['records'][model_before:];values=[r['latency_ms'] for r in rows if r['ok']];cpu=after['cpu_seconds']-before['cpu_seconds'];samples=meter.rows[sample_start:]
            classify=lambda r:'vision' if r['model']=='bench-vision' else 'initial_auxiliary' if str(r['request']['messages'][0].get('content','')).startswith('你负责正式处理前') else 'primary_chat'
            purposes={purpose:sum(classify(r)==purpose for r in records) for purpose in ['primary_chat','initial_auxiliary','vision']}
            actual=[r['elapsed_ms'] for r in records if 'elapsed_ms' in r]
            result['workloads'][label]={'model_call_purposes':purposes,'provider_actual_service_p50_ms':quantile(actual,.5) if actual else None,'provider_actual_service_raw_ms':actual,'count':count,'concurrency':concurrency,'successes':len(values),'errors':count-len(values),'elapsed_seconds':elapsed,'successful_throughput_per_s':len(values)/elapsed,'p50_ms':quantile(values,.5) if values else None,'p95_ms':quantile(values,.95) if values else None,'p99_ms':quantile(values,.99) if values else None,'gateway_cpu_seconds':cpu,'gateway_cpu_ms_per_success':cpu*1000/len(values) if values else None,'gateway_peak_rss_bytes':max([after['rss_bytes']]+[x['rss_bytes'] for x in samples]),'server_cpu_seconds':server_meter.snapshot()['cpu_seconds']-server_before['cpu_seconds'],'server_peak_rss_bytes':max([server_meter.snapshot()['rss_bytes']]+[x['rss_bytes'] for x in server_meter.rows[server_sample_start:]]),'model_calls':len(records),'model_payload_bytes':sum(x['payload_bytes'] for x in records),'rows':rows}
            (out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
            print(json.dumps({'run':name,'workload':label,**{k:v for k,v in result['workloads'][label].items() if k not in ['rows']}}),flush=True)
        workload('chat_cold_c1',n,1);workload('chat_warm_c1',n,1,warm=True);workload('chat_c4',n,4);workload('memory_text_c1',max(10,n//2),1,memory=True);workload('memory_jpeg_c4',max(12,n//2),4,memory=True,image=True)
        result['after_workloads']=meter.snapshot();result['model_records']=http(model,'/metrics');(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));return result
      finally:
        if meter:(out/'process-samples.json').write_text(json.dumps(meter.close()))
        if server_meter:(out/'server-process-samples.json').write_text(json.dumps(server_meter.close()))
        # Save original baseline startup/source receipts before deleting isolated state.
        receipt=state/'hermes/startup_receipt.json'
        if receipt.exists():__import__('shutil').copy2(receipt,out/'python-startup-receipt.json')
        for p in reversed(procs):
            if p.poll() is None:
                try:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
        for f in logs:f.close()

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'hermes-rust-core/results/original-components-final');p.add_argument('--server-binary',type=Path,required=True);p.add_argument('--server-variant',required=True);p.add_argument('--rust-binary',type=Path,required=True);p.add_argument('--python-binary',type=Path,default=PYTHON);p.add_argument('--variants',nargs='+',default=['python','rust']);p.add_argument('--delays',nargs='+',type=int,default=[0,100]);p.add_argument('--trials',type=int,default=3);p.add_argument('--n',type=int,default=40);p.add_argument('--smoke',action='store_true');a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False);all_results=[]
 for trial in range(a.trials):
  for delay in a.delays:
   for variant in (a.variants if trial%2==0 else list(reversed(a.variants))):
    try:all_results.append(run_variant(a,variant,trial,delay))
    except Exception as e:
      failure={'variant':variant,'trial':trial,'delay_ms':delay,'error':str(e)};all_results.append(failure);print(json.dumps(failure),flush=True)
    (a.out/'all-results.json').write_text(json.dumps(all_results,ensure_ascii=False,indent=2))
 if any('error' in result or any(workload.get('errors',0) for workload in result.get('workloads',{}).values()) for result in all_results):
  raise SystemExit('Component comparison recorded a setup/request failure; inspect raw results.')
