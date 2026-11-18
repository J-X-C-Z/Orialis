#!/usr/bin/env python3
"""Same final example, verified synthetic owner, derived cache enabled/disabled.
No parser substitution; fixed byte-identical synthetic fixtures and raw samples.
"""
import argparse, collections, json, math, statistics
from pathlib import Path
from profile_document_history import ROOT, run, sha

def main(a):
    a.out.mkdir(parents=True,exist_ok=False)
    cases=[]
    for file in ['pdf-2pages.pdf','docx-1500paragraphs.docx','xlsx-2000rows.xlsx']:
        for history in [1,8]:cases.append((file,'hydrate',history,history,100000))
    for budget in [8192,100000]:cases.append(('pdf-128pages.pdf','hydrate',1,1,budget))
    for population in [1,512]:cases.append(('pdf-2pages.pdf','fetch',1,population,100000))
    for file in ['pdf-2pages.pdf','docx-1500paragraphs.docx','hash-only-20mib.bin']:cases.append((file,'hash',1,1,100000))
    cases.append(('pdf-2pages.pdf','extract',1,1,100000))
    rows=[]
    for trial in range(a.trials):
        for file,operation,history,population,budget in (cases if trial%2==0 else list(reversed(cases))):
            signatures=set()
            for enabled in ([False,True] if trial%2==0 else [True,False]):
                mode='cache_on' if enabled else 'cache_off';fixture=a.fixtures/file
                command=[str(a.binary),'--file',str(fixture.resolve()),'--mime','application/pdf' if fixture.suffix=='.pdf' else 'application/octet-stream','--mode',operation,'--iterations',str(a.iterations),'--history',str(history),'--population',str(population),'--budget',str(budget)]
                if not enabled:command.append('--disable-cache')
                result=run(command);result.update(trial=trial+1,variant=mode)
                signatures.add((result['file_sha256'],result['output_sha256'],result['output_bytes'],result['truncated']))
                assert result['download_requests_measured']==0
                if enabled and operation=='hydrate':assert result['cache_measured_hits']==a.iterations*history and result['cache_measured_misses']==0
                if not enabled:assert result['cache_entries']==0 and result['cache_measured_hits']==0
                filename=f'trial-{trial+1}-{mode}-{fixture.stem}-{operation}-h{history}-p{population}-b{budget}.json'
                (a.out/filename).write_text(json.dumps(result,indent=2)+'\n');rows.append(result)
                print(json.dumps({k:result[k] for k in ['trial','variant','file','mode','history_messages','cache_population','p50_ms','combined_cpu_ms_per_iteration','cache_measured_hits']}),flush=True)
            assert len(signatures)==1,('on/off fixture or canonical extracted output differs',file,operation,history,budget)
    groups=collections.defaultdict(list)
    for row in rows:groups[(row['variant'],row['file'],row['mode'],row['history_messages'],row['cache_population'],row['remaining_text_budget'])].append(row)
    summary=[]
    for key,group in groups.items():
        values=sorted(v for row in group for v in row['raw_ms']);q=lambda pct:values[min(len(values)-1,math.ceil(len(values)*pct)-1)]
        row=dict(zip(['variant','file','operation','history','population','budget'],key));row.update(iterations=len(values),p50_ms=q(.5),p95_ms=q(.95),p99_ms=q(.99),cpu_ms=statistics.mean(r['combined_cpu_ms_per_iteration'] for r in group),peak_rss_mib=max(r['sampled_process_tree_peak_rss_bytes'] for r in group)/1048576,cache_bytes=max(r['cache_bytes'] for r in group),measured_cache_hits=sum(r['cache_measured_hits'] for r in group),first_unprimed_p50_ms=statistics.median(r['first_unprimed_operation_ms'] for r in group));summary.append(row)
    report={'scope':'Same binary cache-off/cache-on component comparison; same explicit synthetic owner, same secure file/hash verification path; no production account or full gateway claim.','binary_sha256':sha(a.binary),'script_sha256':sha(Path(__file__)),'example_sha256':sha(ROOT/'hermes-rust-core/examples/profile_documents.rs'),'iterations':a.iterations,'trials':a.trials,'operations':sum(r['iterations'] for r in rows),'canonical_inputs_and_outputs_equal':True,'summary':summary,'limitations':['Shared unpinned executor, no confidence intervals.','Eight history inputs contain identical fixture bytes but different source IDs, so cache-on may share one same-conversation derived entry.','Zero measured HTTP downloads in both modes; validation and result destruction excluded from timed operations.','Cache-off retains secure same-FD content hashing and configured Poppler executable identity hashing before parsing.','Process-tree RSS sampling includes setup/warmups and may miss short-process peaks.','This does not reduce provider history bytes, model token use, WAN or Flutter render time.']}
    (a.out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--fixtures',type=Path,default=ROOT/'hermes-rust-core/results/document-profile-baseline/fixtures');p.add_argument('--out',type=Path,required=True);p.add_argument('--iterations',type=int,default=30);p.add_argument('--trials',type=int,default=3);a=p.parse_args();assert a.iterations>0 and a.trials>0;main(a)
