#!/usr/bin/env python3
"""Synthetic, reproducible real-parser and historical-hydration component profile.
No source edits, production files, external providers, ptrace, or gateway claims.
"""
import argparse, hashlib, json, os, platform, subprocess, time
from pathlib import Path
import psutil

ROOT=Path(__file__).resolve().parents[2]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def fixtures(out):
    from reportlab.pdfgen.canvas import Canvas
    from docx import Document
    from openpyxl import Workbook
    from pptx import Presentation
    from pptx.util import Inches
    out.mkdir(parents=True,exist_ok=True)
    text="Synthetic Orialis document data for bounded extraction measurements. "
    for pages in [2,32,128]:
        path=out/f"pdf-{pages}pages.pdf";canvas=Canvas(str(path),invariant=1,pageCompression=1)
        for page in range(pages):
            for line in range(40):canvas.drawString(36,800-line*18,f"Page {page+1:03} row {line:02} "+text)
            canvas.showPage()
        canvas.save()
    for paragraphs in [50,1500]:
        doc=Document();doc.add_heading("Synthetic extraction benchmark",0)
        for i in range(paragraphs):doc.add_paragraph(f"Paragraph {i:04}: {text}")
        doc.save(out/f"docx-{paragraphs}paragraphs.docx")
    wb=Workbook();sheet=wb.active;sheet.title="Synthetic data"
    for row in range(2000):sheet.append([f"record-{row:04}",row,row*2,"Synthetic repeated text",True])
    wb.save(out/"xlsx-2000rows.xlsx")
    presentation=Presentation()
    for i in range(40):
        slide=presentation.slides.add_slide(presentation.slide_layouts[6]);box=slide.shapes.add_textbox(Inches(1), Inches(1), Inches(8), Inches(5))
        box.text_frame.text=f"Synthetic slide {i:02}\n"+text*10
    presentation.save(out/"pptx-40slides.pptx")
    (out/"hash-only-20mib.bin").write_bytes(bytes(range(256))*(20*1024*1024//256))
    return sorted(out.iterdir())

def run(command):
    start=time.perf_counter();p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    root=psutil.Process(p.pid);samples=[]
    while p.poll() is None:
        rss=threads=0
        try:processes=[root]+root.children(recursive=True)
        except psutil.NoSuchProcess:processes=[]
        for process in processes:
            try:rss+=process.memory_info().rss;threads+=process.num_threads()
            except psutil.NoSuchProcess:pass
        samples.append({"elapsed_ms":(time.perf_counter()-start)*1000,"rss_bytes":rss,"threads":threads})
        time.sleep(.002)
    stdout,stderr=p.communicate()
    if p.returncode:raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(command)}\n{stderr}")
    result=json.loads(stdout);result["sampled_process_tree_peak_rss_bytes"]=max((s["rss_bytes"] for s in samples),default=0)
    result["process_tree_sampling_nominal_ms"]=2;result["process_tree_rss_samples"]=samples;result["command"]=command
    return result

def main(a):
    a.out.mkdir(parents=True,exist_ok=False)
    files=sorted(a.fixtures.iterdir()) if a.fixtures else fixtures(a.out/"fixtures");cases=[]
    for file in files:
        for mode in (["hash"] if file.suffix==".bin" else ["extract","hash"]):cases.append((file,mode,1,1,100000))
    pdf=next(f for f in files if f.name=="pdf-2pages.pdf");docx=next(f for f in files if f.name=="docx-1500paragraphs.docx")
    for file in [pdf,docx]:
        for history in [1,8]:
            for mode in ["hydrate","fetch"]:cases.append((file,mode,history,history,100000))
    for population in [64,512]:cases.append((pdf,"fetch",1,population,100000))
    cases.append((next(f for f in files if f.name=="pdf-128pages.pdf"),"extract",1,1,8192))
    rows=[]
    for trial in range(a.trials):
        order=cases if trial%2==0 else list(reversed(cases))
        for file,mode,history,population,budget in order:
            name=f"trial-{trial+1}-{file.stem}-{mode}-h{history}-p{population}-b{budget}"
            command=[str(a.binary),"--file",str(file.resolve()),"--mime","application/pdf" if file.suffix==".pdf" else "application/octet-stream","--mode",mode,"--iterations",str(a.iterations),"--history",str(history),"--population",str(population),"--budget",str(budget)]
            result=run(command);result["trial"]=trial+1
            (a.out/f"{name}.json").write_text(json.dumps(result,indent=2)+"\n")
            rows.append({k:v for k,v in result.items() if k not in {"process_tree_rss_samples","command"}})
            print(json.dumps({k:result[k] for k in ["trial","file","mode","history_messages","cache_population","p50_ms","combined_cpu_ms_per_iteration","download_requests_measured"]}),flush=True)
    versions={"python":platform.python_version(),"platform":platform.platform(),"pdftotext":subprocess.run(["/usr/bin/pdftotext","-v"],capture_output=True,text=True).stderr}
    source_hashes={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/"hermes-rust-core/examples/profile_documents.rs",ROOT/"hermes-rust-core/src/document_extract.rs",ROOT/"hermes-rust-core/src/attachments.rs",ROOT/"hermes-rust-core/src/media_runtime.rs",ROOT/"hermes-rust-core/src/lib.rs"]}
    summary={"scope":"Component profile only: real Rust DocumentExtractor / OrialisMediaResolver with synthetic authenticated localhost download fixture. No GatewayRunner, mobile renderer, TLS/WAN or production model.","binary_sha256":sha(a.binary),"source_sha256":source_hashes,"versions":versions,"iterations":a.iterations,"trials":a.trials,"results":rows,"limitations":["Shared executor without CPU pinning; samples are descriptive, not capacity claims.","getrusage CPU includes reaped Poppler children; RSS lifetime peaks are not additive.","Process-tree RSS sampled every nominal 2ms may miss shorter child peaks and includes setup/warmups.","hash mode is standalone trusted-fixture streaming SHA256, not a derived cache or secure cache hit implementation.","Historical hydrate uses real public media resolver repeatedly, not an end-to-end Core or server request.","Each measured hydration has zero download requests; original byte disk cache is warm, derived text extraction is not cached."]}
    (a.out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--binary",type=Path,default=ROOT/"hermes-rust-core/target/release/examples/profile_documents");p.add_argument("--out",type=Path,required=True);p.add_argument("--fixtures",type=Path);p.add_argument("--iterations",type=int,default=30);p.add_argument("--trials",type=int,default=3);a=p.parse_args();assert a.iterations>0 and a.trials>0;main(a)
