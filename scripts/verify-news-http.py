#!/usr/bin/env python3
"""Verify News HTTP against an isolated local database and live public sources.

Requires target/release/orialis-server. Never writes to a configured production API.
Projects data is explicitly synthetic verification data.
"""
import os, pathlib, tempfile, socket, subprocess, time, urllib.request, urllib.error, json, uuid, importlib.util, datetime, sqlite3
root=pathlib.Path(__file__).resolve().parents[1]
work=pathlib.Path(tempfile.mkdtemp(prefix='orialis-news-verify-'))
os.chmod(work,0o700)
s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close()
base=f'http://127.0.0.1:{port}'
publisher=uuid.uuid4().hex;env=os.environ.copy();env.update(ORIALIS_PORT=str(port),ORIALIS_HOST='127.0.0.1',ORIALIS_DATABASE_URL=f'sqlite://{work}/test.db?mode=rwc',ORIALIS_UPLOAD_DIR=str(work/'uploads'),ORIALIS_NEWS_PUBLISHER_TOKEN=publisher,ORIALIS_NEWS_PUBLISHER_USER_ID='unbound')
log=(work/'server.log').open('w');proc=None
checks={}; live={}
def call(method,path,body=None,authorization=None,expected=200):
 headers={'Content-Type':'application/json'}
 if authorization:headers['Authorization']=authorization
 req=urllib.request.Request(base+path,headers=headers,data=None if body is None else json.dumps(body).encode(),method=method)
 try:
  with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=120) as r:status=r.status;value=json.load(r)
 except urllib.error.HTTPError as e:status=e.code;value=json.load(e)
 assert status==expected,(path,status,value)
 return value

def start():
 global proc
 proc=subprocess.Popen([str(root/'target/release/orialis-server')],cwd=work,env=env,stdout=log,stderr=log)
 for _ in range(100):
  try:call('GET','/api/health');return
  except (urllib.error.URLError,ConnectionError):time.sleep(.1)
 raise RuntimeError('isolated test service did not start')

def publish(path,data,source,**extra):
 body={'taskId':str(uuid.uuid4()),'idempotencyKey':str(uuid.uuid4()),'source':source,'generatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'result':data,**extra}
 result=call('POST','/api/v1/news'+path,body,'Bearer '+publisher)
 assert result['status']=='succeeded'
 return body

try:
 start(); password=uuid.uuid4().hex
 a=call('POST','/api/v1/auth/register',{'username':'news_verify_a_'+uuid.uuid4().hex[:8],'password':password},expected=201)
 b=call('POST','/api/v1/auth/register',{'username':'news_verify_b_'+uuid.uuid4().hex[:8],'password':uuid.uuid4().hex},expected=201)
 env['ORIALIS_NEWS_PUBLISHER_USER_ID']=a['userId'];proc.terminate();proc.wait(5);start()
 sa='Session '+a['accessToken'];sb='Session '+b['accessToken']
 call('GET','/api/v1/news/aihot/hot',expected=401);checks['unauthenticated_read_rejected']=True
 assert call('GET','/api/v1/news/projects',authorization=sa)['data']==[];checks['actual_empty_projects']=True
 spec=importlib.util.spec_from_file_location('news_sources',root/'scripts/news_sources.py');src=importlib.util.module_from_spec(spec);spec.loader.exec_module(src)
 data=src.fetch_aihot()
 for kind,items in data['datasets']:
  if items is None or (isinstance(items,dict) and items.get('sourceError')):continue
  publish('/publish/aihot/'+kind,items,'aihot.news');live['aihot_'+kind.replace('/','_')]=len(items) if isinstance(items,list) else bool(items)
 hot=call('GET','/api/v1/news/aihot/hot',authorization=sa);assert len(hot['data'])==10;checks['aihot_top10_real_source_roundtrip']=True
 if data['events']:
  event=data['events'][0]; story_id=event['publicId']
  publish('/publish/aihot/events',event,'aihot.news')
  assert call('GET','/api/v1/news/aihot/events/'+story_id,authorization=sa)['data']
  checks['real_event_detail_roundtrip']=True
 for period in ['daily','weekly']:
  repos=src.fetch_github(period,None);assert repos
  enriched=[src.enrich_repository(x,None) for x in repos[:2]]+repos[2:]
  brief={'title':'HTTP verification '+period,'summary':'Synthetic summary of real collected repositories; not an AI brief','themes':[],'highlights':[],'analysisStatus':'verification','source':'githot.dev'}
  body=publish('/publish/github/'+period,{'repositories':enriched,'brief':brief},'githot.dev',period=period)
  got=call('GET','/api/v1/news/github/'+period,authorization=sa);assert len(got['data'])==len(repos)
  repo=enriched[0]['repository'];assert call('GET','/api/v1/news/github/repos/'+repo,authorization=sa)['data']['repository']==repo
  call('POST','/api/v1/news/publish/github/'+period,body,'Bearer '+publisher);checks['idempotent_'+period]=True
  assert call('GET','/api/v1/news/github/briefs/'+period,authorization=sa)['data']==brief
  checks['github_'+period+'_brief_atomic_projection']=True
  checks['github_'+period+'_real_roundtrip']=True;live['github_'+period+'_count']=len(repos);live['github_'+period+'_metadata_readme']=sum(bool(x.get('readme')) for x in enriched)
 project=call('POST','/api/v1/projects',{'name':'Integration fixture — not a secretary report'},sa,201)
 report={'project':'Integration fixture','date':'2026-10-02','completed':['Synthetic HTTP verification'], 'in_progress':[], 'decisions':[], 'issues':[], 'next':[], 'important':[]}
 publish('/projects/publish',report,'orialis-project-report/integration-fixture',projectId=project['id'],userId=a['userId'],period='daily',reportDate='2026-10-02')
 assert call('GET','/api/v1/news/projects/'+project['id']+'/reports',authorization=sa)['data']
 call('GET','/api/v1/news/projects/'+project['id']+'/reports',authorization=sb,expected=404)
 assert call('GET','/api/v1/news/projects',authorization=sb)['data']==[];checks['secretary_report_user_isolation']=True
 bad={'taskId':str(uuid.uuid4()),'source':'orialis-project-report/test','result':report,'userId':b['userId'],'projectId':project['id'],'period':'daily','reportDate':'2026-10-02'}
 call('POST','/api/v1/news/projects/publish',bad,'Bearer '+publisher,403);checks['publisher_cannot_write_another_user']=True
 evidence={'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'mode':'isolated database; real AIHOT and GitHub rankings; synthetic brief projection and Projects fixtures only','checks':checks,'live':live,'productionChanged':False}
 out=root/'news/evidence';out.mkdir(parents=True,exist_ok=True);(out/'http-integration.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2))
 print(json.dumps(evidence,ensure_ascii=False,indent=2))
except Exception:
 import traceback;traceback.print_exc();print('Server diagnostics directory:',work);raise
finally:
 if proc is not None:proc.terminate();proc.wait(5)
 log.close()
