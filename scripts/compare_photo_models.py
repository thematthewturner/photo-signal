import argparse, base64, hashlib, html, json, random, sqlite3, statistics, shutil
from pathlib import Path
ROOT=Path.home()/'Documents/PhotoSignal-Sandbox/2026-09'
BASE=Path.home()/'Library/Application Support/PhotoSignal/benchmark-comparison'
BASE.mkdir(parents=True,exist_ok=True)
DB=BASE/'comparison.sqlite'
def read(path,default):
 try: return json.loads(path.read_text())
 except (OSError,ValueError): return default
def rows(path):
 if not path.exists(): return []
 return [json.loads(s) for s in path.read_text().splitlines() if s.strip()]
def import_run(conn,run):
 config=read(run/'config.json',{});sample=read(run/'sample.json',{})
 items=sample.get('items',sample.get('samples',[]))
 if not items: return
 rid=str(run);model=config.get('actual_model') or config.get('model_requested') or config.get('model') or run.parent.name
 prompt=config.get('prompt_sha256');schema=config.get('schema_sha256')
 conn.execute('INSERT OR REPLACE INTO runs VALUES(?,?,?,?,?,?)',(rid,model,str(run),prompt,schema,json.dumps(config)))
 metrics={r['sample_id']:r for r in rows(run/'metrics.jsonl')}
 for item in items:
  sid=item['sample_id'];digest=item.get('sha256') or item.get('input_sha256');rel=item.get('relative_path') or 'images-768/'+sid+'.jpg'
  conn.execute('INSERT OR IGNORE INTO images VALUES(?,?,?)',(sid,digest,rel))
  existing=conn.execute('SELECT sha256 FROM images WHERE sample_id=?',(sid,)).fetchone()[0]
  if digest and existing!=digest: raise ValueError('Different image bytes for '+sid)
 for r in rows(run/'predictions.jsonl'):
  sid=r['sample_id'];metric=metrics.get(sid,{})
  classification=r.get('parsed_classification') or r.get('classification')
  elapsed=r.get('total_wall_ms_across_attempts',r.get('total_elapsed_ms',metric.get('end_to_end_ms')))
  cost=r.get('total_cost',{});billed=metric.get('actual_billed_api_cost_usd',cost.get('actual_billed_usd'))
  calculated=r.get('total_cost_usd_list_calculated',cost.get('calculated_usd'))
  conn.execute('INSERT OR REPLACE INTO predictions VALUES(?,?,?,?,?,?,?,?,?)',(rid,sid,r.get('status'),json.dumps(classification),elapsed,billed,calculated,json.dumps(metric),json.dumps(r)))
 for r in rows(run/'attempts.jsonl'):
  conn.execute('INSERT OR REPLACE INTO attempts VALUES(?,?,?,?)',(rid,r['sample_id'],r.get('attempt_number',r.get('attempt',1)),json.dumps(r)))

SCORE_FIELDS={'caption_accuracy','setting_accuracy','activity_accuracy','object_accuracy','detail_coverage','search_usefulness'}
def prediction_digest(classification):
 return hashlib.sha256(json.dumps(classification,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
def validate_review(conn,review):
 if not isinstance(review,dict): raise ValueError('Each review must be an object')
 r=dict(review)
 row=conn.execute('SELECT p.classification_json,i.sha256 FROM predictions p JOIN images i USING(sample_id) WHERE p.run_id=? AND p.sample_id=?',(r.get('run_id'),r.get('sample_id'))).fetchone()
 if row is None: raise ValueError('Unknown prediction in review')
 r['integrity_status']='verified' if r.get('image_sha256') and r.get('prediction_sha256') else 'legacy_without_both_hashes'
 expected_prediction=prediction_digest(json.loads(row[0]))
 if r.get('image_sha256') and r['image_sha256']!=row[1]: raise ValueError('Image hash mismatch in review')
 if r.get('prediction_sha256') and r['prediction_sha256']!=expected_prediction: raise ValueError('Stale prediction hash in review')
 r['image_sha256']=row[1];r['prediction_sha256']=expected_prediction
 kind=r.get('review_kind','human')
 if kind not in {'human','ai'}: raise ValueError('review_kind must be human or ai')
 reviewer=r.get('reviewer') or 'human'
 if not isinstance(reviewer,str) or not reviewer.strip() or len(reviewer)>120: raise ValueError('Invalid reviewer')
 if kind=='ai' and not reviewer.startswith('ai:'): reviewer='ai:'+reviewer
 if kind=='human' and reviewer.startswith('ai:'): raise ValueError('Human reviewer cannot use AI reviewer prefix')
 r['reviewer']=reviewer;r['review_kind']=kind
 for key in SCORE_FIELDS:
  value=r.get(key)
  if isinstance(value,str) and value in {'1','2','3','4','5'}: value=int(value);r[key]=value
  if value=='' : value=None;r[key]=None
  if value is not None and value!='N/A' and (isinstance(value,bool) or not isinstance(value,(int,float)) or value not in {1,2,3,4,5}): raise ValueError('Invalid score: '+key)
 count=r.get('hallucination_count')
 if count is not None and (isinstance(count,bool) or not isinstance(count,int) or count<0):raise ValueError('Invalid hallucination count')
 if r.get('overall_acceptable') not in {None,'yes','no'}:raise ValueError('Invalid overall judgment')
 for field in ['unsupported_claims','important_missed_details','transcription_errors','notes']:
  value=r.get(field)
  if value is not None and not isinstance(value,(str,list)): raise ValueError('Invalid notes: '+field)
  if value is not None and len(json.dumps(value))>20000:raise ValueError('Review notes too long')
 return r

def render_page(template,data):
 text=template.read_text()
 if text.count('__BAKEOFF_DATA__')!=1:raise ValueError('Expected one bake-off data placeholder')
 payload=json.dumps(data,ensure_ascii=False).replace('<',r'\u003c').replace('\u2028',r'\u2028').replace('\u2029',r'\u2029')
 return text.replace('__BAKEOFF_DATA__',payload)

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--run',action='append',type=Path,default=[]);parser.add_argument('--evaluation',type=Path);a=parser.parse_args()
 conn=sqlite3.connect(DB);conn.executescript('''
 CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY, model TEXT, path TEXT,prompt_hash TEXT,schema_hash TEXT,config_json TEXT);
 CREATE TABLE IF NOT EXISTS images(sample_id TEXT PRIMARY KEY,sha256 TEXT,relative_path TEXT);
 CREATE TABLE IF NOT EXISTS predictions(run_id TEXT,sample_id TEXT,status TEXT,classification_json TEXT,elapsed_ms REAL,billed_usd REAL,calculated_usd REAL,metrics_json TEXT,raw_json TEXT,PRIMARY KEY(run_id,sample_id));
 CREATE TABLE IF NOT EXISTS attempts(run_id TEXT,sample_id TEXT,attempt_number INTEGER,raw_json TEXT,PRIMARY KEY(run_id,sample_id,attempt_number));
 CREATE TABLE IF NOT EXISTS reviews(run_id TEXT,sample_id TEXT,reviewer TEXT,review_json TEXT,PRIMARY KEY(run_id,sample_id,reviewer));
 ''')
 for run in a.run: import_run(conn,run)
 if a.evaluation:
  data=json.loads(a.evaluation.read_text())
  if not isinstance(data,dict) or not isinstance(data.get('reviews'),list): raise ValueError('Expected an object with a reviews array')
  normalized=[validate_review(conn,r) for r in data['reviews']]
  for r in normalized:
   conn.execute('INSERT OR REPLACE INTO reviews VALUES(?,?,?,?)',(r['run_id'],r['sample_id'],r['reviewer'],json.dumps(r)))
 conn.commit();conn.row_factory=sqlite3.Row
 runs=[dict(r) for r in conn.execute('SELECT * FROM runs ORDER BY model')]
 records=[dict(r) for r in conn.execute('SELECT * FROM predictions')]
 for r in records:
  r['classification']=json.loads(r.pop('classification_json'))
  r['prediction_sha256']=prediction_digest(r['classification'])
  r['metrics']=json.loads(r['metrics_json'] or '{}')
  r['image_sha256']=conn.execute('SELECT sha256 FROM images WHERE sample_id=?',(r['sample_id'],)).fetchone()[0]
 for run in runs: run['config']=json.loads(run['config_json'] or '{}')
 images=[dict(r) for r in conn.execute('SELECT * FROM images ORDER BY sample_id')]
 # Copy already cached images without accessing stalled source files.
 (BASE/'images').mkdir(exist_ok=True)
 for i in images:
  cached=Path.home()/'Library/Application Support/PhotoSignal/benchmark-cache'/(i['sample_id']+'-fireworks.jpg')
  if not cached.exists(): cached=Path.home()/'Library/Application Support/PhotoSignal/benchmark-cache'/(i['sample_id']+'.jpg')
  if cached.exists():
   blob=cached.read_bytes()
   if hashlib.sha256(blob).hexdigest()!=i['sha256']:raise ValueError('Preview hash mismatch')
   shutil.copyfile(cached,BASE/'images'/(i['sample_id']+'.jpg'))
   i['thumbnail_base64']=base64.b64encode(blob).decode()
 data={'runs':runs,'records':records,'images':images,'reviews':[json.loads(r[0]) for r in conn.execute('SELECT review_json FROM reviews')]}
 data['ai_evaluation']=read(BASE/'ai-judge-summary.json',None)
 (BASE/'comparison-data.json').write_text(json.dumps(data,indent=2))
 template=Path(__file__).resolve().parents[1]/'web/grader.html'
 page=render_page(template,data)
 (BASE/'index.html').write_text(page)
 (BASE/'ai-results.html').write_text(page)
 print(json.dumps({'database':str(DB),'review':str(BASE/'index.html'),'runs':len(runs),'predictions':len(records)}))
if __name__=='__main__':main()
