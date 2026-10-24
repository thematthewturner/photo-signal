#!/usr/bin/env python3
"""Build an offline aggregate dashboard from a read-only, consistent SQLite snapshot."""
import argparse,collections,datetime,json,os,pathlib,sqlite3,time
os.umask(0o077)
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEFAULT=pathlib.Path.home()/'Library/Application Support/PhotoSignal'
BUCKETS=[.1,.3,.5,.8]

def segment():
 return dict(total=0,photos=0,videos=0,favorites=0,analyzed=0,unavailable=0,unattempted=0,stale=0,vectors=0,gps=0,ocr=0,ocrComplete=0,ocrFailed=0,faces=collections.Counter(),status=collections.Counter(),camera=collections.Counter(),formats=collections.Counter(),albums=collections.Counter(),orientation=collections.Counter(),subtypes=collections.Counter(),resolution=collections.Counter(),tags=[collections.Counter() for _ in BUCKETS],fields=collections.Counter(),fieldTypes={},duration=0)

def present(v):return v is not None and v!='' and v!=[] and v!={}

def walk(obj,prefix=''):
 for k,v in obj.items():
  if k in ['feature_print_base64','metadata']:continue
  path=prefix+k
  if isinstance(v,dict):
   yield path,v
   yield from walk(v,path+'.')
  else:
   yield path,v
   if isinstance(v,list):
    for item in v:
     if isinstance(item,dict):yield from walk(item,path+'[].')

def build(db_path,output,template):
 started=time.perf_counter();currentYear=str(datetime.datetime.now().year);c=sqlite3.connect(db_path.as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row;c.execute('BEGIN')
 groups={};fieldtypes={'vectors.feature_print':{'binary blob'},'vectors.model':{'text'},'vectors.revision':{'number'},'catalog.camera_model':{'text'},'catalog.filename':{'text'}};firstDate=None;lastDate=None
 query='''SELECT a.*,n.raw_json AS analysis_json,n.face_count,n.source_modified_at,
 EXISTS(SELECT 1 FROM vectors v WHERE v.asset_id=a.asset_id AND v.source_modified_at IS a.modified_at) AS has_vector
 FROM assets a LEFT JOIN analysis n USING(asset_id) WHERE a.active=1'''
 for row in c.execute(query):
  meta=json.loads(row['raw_json']);analysis=json.loads(row['analysis_json']) if row['analysis_json'] else {}
  date=row['created_at'] or '';year=date[:4] if len(date)>=4 else 'Unknown'
  media={1:'Photo',2:'Video',3:'Audio'}.get(row['media_type'],'Other');key=(year,media)
  s=groups.setdefault(key,segment());s['total']+=1;s['photos']+=media=='Photo';s['videos']+=media=='Video';s['favorites']+=bool(row['favorite']);s['vectors']+=row['has_vector']
  if date and '1900'<=year<=currentYear:firstDate=min(firstDate or date,date);lastDate=max(lastDate or date,date)
  s['gps']+=isinstance(meta.get('location'),dict) and 'latitude' in meta['location']
  state=analysis.get('status','not_attempted');fresh=bool(analysis) and row['source_modified_at']==row['modified_at']
  analyzed=fresh and state in ['complete','partial'];s['analyzed']+=analyzed;s['unavailable']+=fresh and state in ['no_local_preview','preview_decode_failed'];s['unattempted']+=not bool(analysis);s['stale']+=bool(analysis) and not fresh;s['status'][state if fresh else 'stale' if analysis else 'not_attempted']+=1
  if analyzed and row['face_count'] is not None:s['faces'][str(row['face_count']) if row['face_count']<5 else '5+']+=1
  s['ocr']+=analyzed and bool(analysis.get('ocr_text','').strip());s['ocrComplete']+=analyzed and ('ocr_text' in analysis);s['ocrFailed']+=analyzed and analysis.get('ocr_status')=='failed_isolated'
  camera=analysis.get('camera_metadata',{})
  model=row['camera_model'] or camera.get('Model')
  if model:s['camera'][str(model)]+=1
  resources=meta.get('resources',[])
  for fmt in set(str(r.get('uti','Unknown')) for r in resources):s['formats'][fmt]+=1
  for name in set(a.get('title','Untitled') for a in meta.get('albums',[])):s['albums'][name]+=1
  w,h=row['width'] or 0,row['height'] or 0
  s['orientation']['Landscape' if w>h else 'Portrait' if h>w else 'Square' if w else 'Unknown']+=1
  mp=w*h/1e6;s['resolution']['<2 MP' if mp<2 else '2–8 MP' if mp<8 else '8–16 MP' if mp<16 else '16–32 MP' if mp<32 else '32+ MP']+=1
  s['duration']+=row['duration'] or 0
  bits=int(meta.get('media_subtypes',0));flags={'Panorama':1,'HDR':2,'Screenshot':4,'Live Photo':8,'Depth effect':16} if media=='Photo' else {'High frame rate':131072,'Time lapse':262144} if media=='Video' else {}
  for label,bit in flags.items():
   if bits&bit:s['subtypes'][label]+=1
  if meta.get('represents_burst'):s['subtypes']['Burst representative']+=1
  if row['has_vector']:
   s['fields']['vectors.feature_print']+=1;s['fields']['vectors.model']+=1;s['fields']['vectors.revision']+=1
  for name,value in [('catalog.camera_model',row['camera_model']),('catalog.filename',row['filename'])]:
   if present(value):s['fields'][name]+=1
  if analyzed:
   for threshold,counts in zip(BUCKETS,s['tags']):
    for label in set(t.get('label','') for t in analysis.get('labels',[]) if t.get('confidence',0)>=threshold):
     if label:counts[label]+=1
  fields=list(walk(meta,'photos.'))+(list(walk(analysis,'analysis.')) if analyzed else [])
  for name,value in dict(fields).items():
   kind='object' if isinstance(value,dict) else 'list' if isinstance(value,list) else 'boolean' if isinstance(value,bool) else 'number' if isinstance(value,(int,float)) else 'text' if isinstance(value,str) else 'null'
   fieldtypes.setdefault(name,set()).add(kind)
   if present(value):s['fields'][name]+=1
 people=[dict(r) for r in c.execute("SELECT p.name,count(*) AS count FROM people p JOIN assets a USING(asset_id) WHERE a.active=1 AND p.source='user_confirmed' GROUP BY p.name ORDER BY count(*) DESC")]
 for (year,media),s in groups.items():s['year']=year;s['media']=media;s.pop('fieldTypes')
 payload={'generated':datetime.datetime.now().astimezone().isoformat(),'snapshotSeconds':round(time.perf_counter()-started,1),'groups':list(groups.values()),'thresholds':BUCKETS,'fieldTypes':{k:sorted(v) for k,v in fieldtypes.items()},'people':people,'dates':[firstDate,lastDate],'databaseBytes':db_path.stat().st_size,'snapshotYear':int(currentYear)}
 c.rollback();c.close()
 output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 serialized=json.dumps(payload,separators=(',',':'),ensure_ascii=False).replace('<','\\u003c').replace('>','\\u003e').replace('&','\\u0026')
 html=template.read_text().replace('/*__PROFILE_DATA__*/',serialized)
 temporary=output.with_suffix('.tmp');temporary.write_text(html);temporary.chmod(0o600);temporary.replace(output)
 summary={'assets':sum(s['total'] for s in groups.values()),'analyzed':sum(s['analyzed'] for s in groups.values()),'unavailable':sum(s['unavailable'] for s in groups.values()),'stale':sum(s['stale'] for s in groups.values()),'years':len(set(k[0] for k in groups)),'fields':len(fieldtypes),'output':str(output),'htmlBytes':output.stat().st_size,'seconds':round(time.perf_counter()-started,2)}
 print(json.dumps(summary));return summary

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--database',type=pathlib.Path,default=DEFAULT/'catalog.sqlite');p.add_argument('--output',type=pathlib.Path,default=DEFAULT/'profile/index.html');p.add_argument('--template',type=pathlib.Path,default=ROOT/'web/profile.html');args=p.parse_args()
 build(args.database.resolve(),args.output,args.template)
