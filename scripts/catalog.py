#!/usr/bin/env python3
"""Private SQLite catalog and bounded, local-only natural-language query planner."""
import argparse, datetime as dt, json, os, pathlib, re, sqlite3, sys, time, urllib.request, base64
os.umask(0o077)
BASE = pathlib.Path.home() / 'Library/Application Support/PhotoSignal'

def connect(base=BASE):
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(base / 'catalog.sqlite', timeout=30)
    db.row_factory = sqlite3.Row
    db.executescript('''
    PRAGMA journal_mode=WAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS assets (
      asset_id TEXT PRIMARY KEY, created_at TEXT, modified_at TEXT, media_type INTEGER,
      width INTEGER, height INTEGER, duration REAL, favorite INTEGER, active INTEGER NOT NULL DEFAULT 1,
      camera_model TEXT, filename TEXT, albums TEXT, raw_json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS assets_created ON assets(active,created_at DESC);
    CREATE INDEX IF NOT EXISTS assets_media ON assets(active,media_type,created_at DESC);
    CREATE INDEX IF NOT EXISTS assets_favorite ON assets(active,favorite,created_at DESC);
    CREATE INDEX IF NOT EXISTS assets_order ON assets(active,created_at DESC,asset_id);
    CREATE INDEX IF NOT EXISTS assets_camera ON assets(camera_model);
    CREATE TABLE IF NOT EXISTS people (
      asset_id TEXT NOT NULL REFERENCES assets(asset_id), name TEXT COLLATE NOCASE NOT NULL,
      source TEXT NOT NULL, confirmed_at TEXT, PRIMARY KEY(asset_id,name,source)
    );
    CREATE INDEX IF NOT EXISTS people_name ON people(name,source,asset_id);
    CREATE TABLE IF NOT EXISTS analysis (
      asset_id TEXT PRIMARY KEY REFERENCES assets(asset_id), face_count INTEGER,
      source_modified_at TEXT, pipeline_version TEXT, labels_json TEXT, ocr_text TEXT,
      raw_json TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS analysis_faces ON analysis(face_count,asset_id);
    CREATE TABLE IF NOT EXISTS vectors (
      asset_id TEXT NOT NULL REFERENCES assets(asset_id), model TEXT NOT NULL,
      revision INTEGER NOT NULL, source_modified_at TEXT, data BLOB NOT NULL,
      PRIMARY KEY(asset_id,model,revision)
    );
    CREATE TABLE IF NOT EXISTS collections (
      collection_id INTEGER PRIMARY KEY, name TEXT NOT NULL, query_json TEXT NOT NULL, created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS collection_items (
      collection_id INTEGER REFERENCES collections(collection_id), asset_id TEXT REFERENCES assets(asset_id),
      PRIMARY KEY(collection_id,asset_id)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(asset_id UNINDEXED, text, tokenize='unicode61');
    CREATE TABLE IF NOT EXISTS import_state(path TEXT PRIMARY KEY, size INTEGER, mtime REAL);
    CREATE TABLE IF NOT EXISTS semantic_metadata (
      asset_id TEXT PRIMARY KEY REFERENCES assets(asset_id), source_modified_at TEXT,
      model TEXT NOT NULL, input_sha256 TEXT NOT NULL, prompt_sha256 TEXT NOT NULL,
      classification_json TEXT NOT NULL, search_text TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    ''')
    return db

def upsert_asset(db, row):
    aid = row.get('asset_id')
    if not isinstance(aid, str): return
    resources = row.get('resources', [])
    filename = row.get('filename') or ' '.join(str(r.get('filename','')) for r in resources)
    album_text = ' '.join(str(a.get('title','')) for a in row.get('albums', []))
    db.execute('''INSERT INTO assets(asset_id,created_at,modified_at,media_type,width,height,duration,favorite,filename,albums,raw_json)
    VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(asset_id) DO UPDATE SET
      created_at=excluded.created_at,modified_at=excluded.modified_at,media_type=excluded.media_type,
      width=excluded.width,height=excluded.height,duration=excluded.duration,favorite=excluded.favorite,
      filename=excluded.filename,albums=excluded.albums,raw_json=excluded.raw_json,active=1''',
      (aid,row.get('created_at'),row.get('modified_at'),row.get('media_type',1),row.get('width'),row.get('height'),
       row.get('duration',0),int(row.get('favorite',False)),filename,album_text,json.dumps(row)))

def upsert_analysis(db, row):
    aid = row.get('asset_id')
    if not aid: return
    if not db.execute('SELECT 1 FROM assets WHERE asset_id=?',(aid,)).fetchone():
        upsert_asset(db,dict(row.get('metadata',{}),asset_id=aid))
    metadata = row.get('metadata',{})
    camera = row.get('camera_metadata',{}).get('Model')
    if camera: db.execute('UPDATE assets SET camera_model=? WHERE asset_id=?',(camera,aid))
    existing = db.execute('SELECT raw_json FROM analysis WHERE asset_id=?',(aid,)).fetchone()
    old = json.loads(existing[0]) if existing else {}
    # Older sample imports cannot replace newer enriched analysis.
    if old.get('pipeline_version') and not row.get('pipeline_version'): return
    vector = row.pop('feature_print_base64', None)
    db.execute('''INSERT INTO analysis VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(asset_id) DO UPDATE SET
      face_count=excluded.face_count,source_modified_at=excluded.source_modified_at,pipeline_version=excluded.pipeline_version,
      labels_json=excluded.labels_json,ocr_text=excluded.ocr_text,raw_json=excluded.raw_json,updated_at=excluded.updated_at''',
      (aid,row.get('face_count'),metadata.get('modified_at'),row.get('pipeline_version'),json.dumps(row.get('labels',[])),
       row.get('ocr_text',''),json.dumps(row),dt.datetime.now(dt.timezone.utc).isoformat()))
    if vector:
        db.execute('INSERT OR REPLACE INTO vectors VALUES(?,?,?,?,?)',(aid,'apple-vision-feature-print',row.get('feature_revision',0),metadata.get('modified_at'),base64.b64decode(vector,validate=True)))

def rebuild_fts(db):
    db.execute('DELETE FROM search_fts')
    db.execute('''INSERT INTO search_fts(rowid,asset_id,text)
    SELECT a.rowid,a.asset_id, coalesce(a.filename,'') || ' ' || coalesce(a.albums,'') || ' ' || coalesce(a.camera_model,'') || ' ' ||
      coalesce((SELECT group_concat(name,' ') FROM people p WHERE p.asset_id=a.asset_id),'') || ' ' ||
      coalesce(n.ocr_text,'') || ' ' || coalesce(n.labels_json,'') || ' ' || coalesce(s.search_text,'')
    FROM assets a LEFT JOIN analysis n ON n.asset_id=a.asset_id AND n.source_modified_at IS a.modified_at
    LEFT JOIN semantic_metadata s ON s.asset_id=a.asset_id AND s.source_modified_at IS a.modified_at WHERE a.active=1''')

def refresh_search_asset(db, aid):
    row = db.execute('''SELECT a.rowid,a.asset_id,a.filename,a.albums,a.camera_model,n.ocr_text,n.labels_json,s.search_text
      FROM assets a LEFT JOIN analysis n ON n.asset_id=a.asset_id AND n.source_modified_at IS a.modified_at
      LEFT JOIN semantic_metadata s ON s.asset_id=a.asset_id AND s.source_modified_at IS a.modified_at
      WHERE a.asset_id=? AND a.active=1''',(aid,)).fetchone()
    if row:
        names=' '.join(r[0] for r in db.execute('SELECT name FROM people WHERE asset_id=?',(aid,)))
        db.execute('DELETE FROM search_fts WHERE rowid=?',(row[0],))
        db.execute('INSERT INTO search_fts(rowid,asset_id,text) VALUES(?,?,?)',(row[0],aid,' '.join(str(v or '') for v in row[2:])+' '+names))

def sync(db,base=BASE):
    begin = time.perf_counter(); changed = False; full_rebuild = False; dirty = set()
    paths = [base/'inventory.jsonl'] + sorted(base.glob('benchmark-archive-*.json')) + [base/'benchmark.json',base/'analysis.jsonl',base/'album-membership.json',base/'people-tags.json']
    with db:
        for path in paths:
            if not path.exists(): continue
            stat=path.stat(); prior=db.execute('SELECT size,mtime FROM import_state WHERE path=?',(str(path),)).fetchone()
            if prior and prior['size']==stat.st_size and prior['mtime']==stat.st_mtime and not (full_rebuild and path.name=='album-membership.json'): continue
            if path.name=='inventory.jsonl':
                full_rebuild = True
                db.execute('UPDATE assets SET active=0')
                with path.open() as f:
                    for line in f:
                        if line.strip(): upsert_asset(db,json.loads(line))
            elif path.name=='album-membership.json':
                dirty.update(r[0] for r in db.execute("SELECT asset_id FROM assets WHERE albums<>''"))
                db.execute("UPDATE assets SET albums='',raw_json=json_set(raw_json,'$.albums',json('[]')) WHERE albums<>''")
                for aid,albums in json.loads(path.read_text()).items():
                    existing=db.execute('SELECT raw_json FROM assets WHERE asset_id=?',(aid,)).fetchone()
                    if not existing: continue
                    metadata=json.loads(existing[0]);metadata['albums']=albums
                    db.execute('UPDATE assets SET albums=?,raw_json=? WHERE asset_id=?',(' '.join(a.get('title','') for a in albums),json.dumps(metadata),aid));dirty.add(aid)
            elif path.name=='people-tags.json':
                tags=json.loads(path.read_text())
                dirty.update(r[0] for r in db.execute('SELECT DISTINCT asset_id FROM people'))
                db.execute("DELETE FROM people WHERE source='user_confirmed'")
                for aid,tag in tags.items():
                    if not db.execute('SELECT 1 FROM assets WHERE asset_id=?',(aid,)).fetchone(): continue
                    dirty.add(aid)
                    for name in tag.get('people',[]):
                        db.execute('INSERT OR REPLACE INTO people VALUES(?,?,?,?)',(aid,name,'user_confirmed',tag.get('confirmed_at')))
            elif path.name=='analysis.jsonl':
                offset = prior['size'] if prior and prior['size'] <= stat.st_size else 0
                with path.open('rb') as f:
                    f.seek(offset)
                    while True:
                        line = f.readline()
                        if not line: break
                        if not line.strip(): offset=f.tell();continue
                        try: row=json.loads(line)
                        except json.JSONDecodeError:
                            if not line.endswith(b'\n'): break
                            offset=f.tell();continue
                        upsert_analysis(db,row);dirty.add(row['asset_id']);offset=f.tell()
                db.execute('INSERT OR REPLACE INTO import_state VALUES(?,?,?)',(str(path),offset,stat.st_mtime))
                changed=True
                continue
            else:
                for row in json.loads(path.read_text()).get('rows',[]): upsert_analysis(db,row);dirty.add(row['asset_id'])
            db.execute('INSERT OR REPLACE INTO import_state VALUES(?,?,?)',(str(path),stat.st_size,stat.st_mtime));changed=True
        if full_rebuild: rebuild_fts(db)
        elif changed:
            for aid in dirty:
                asset_rowid=db.execute('SELECT rowid FROM assets WHERE asset_id=?',(aid,)).fetchone()
                if not asset_rowid: continue
                db.execute('DELETE FROM search_fts WHERE rowid=?',(asset_rowid[0],))
                row=db.execute('''SELECT a.filename,a.albums,a.camera_model,n.ocr_text,n.labels_json FROM assets a LEFT JOIN analysis n ON n.asset_id=a.asset_id AND n.source_modified_at IS a.modified_at WHERE a.asset_id=? AND a.active=1''',(aid,)).fetchone()
                if row:
                    names=' '.join(r[0] for r in db.execute('SELECT name FROM people WHERE asset_id=?',(aid,)))
                    refresh_search_asset(db,aid)
    return {'assets':db.execute('SELECT count(*) FROM assets WHERE active=1').fetchone()[0],
      'analyzed':db.execute('SELECT count(*) FROM analysis n JOIN assets a USING(asset_id) WHERE a.active=1').fetchone()[0],
      'enriched':db.execute("SELECT count(*) FROM analysis n JOIN assets a USING(asset_id) WHERE a.active=1 AND n.pipeline_version IS NOT NULL").fetchone()[0],
      'vectors':db.execute('SELECT count(*) FROM vectors').fetchone()[0],
      'confirmed_people_tags':db.execute('SELECT count(*) FROM people').fetchone()[0],
      'sync_seconds':round(time.perf_counter()-begin,3)}

ALLOWED={'text','people_all','after','before','favorite','media','min_faces','camera','limit'}
def validate(plan):
    if not isinstance(plan,dict) or set(plan)-ALLOWED: raise ValueError('Unsupported search fields')
    p=dict(plan)
    for key in ['text','camera']:
        if key in p and (not isinstance(p[key],str) or len(p[key])>500): raise ValueError('Invalid '+key)
    if 'people_all' in p and (not isinstance(p['people_all'],list) or len(p['people_all'])>10 or any(not isinstance(n,str) or len(n)>100 for n in p['people_all'])): raise ValueError('Invalid people list')
    for key in ['after','before']:
        if key in p: dt.date.fromisoformat(p[key])
    if 'favorite' in p and not isinstance(p['favorite'],bool): raise ValueError('favorite must be boolean')
    if p.get('media','photo') not in ['photo','video','any']: raise ValueError('Unknown media type')
    if 'min_faces' in p and (type(p['min_faces']) is not int or not 0<=p['min_faces']<=100): raise ValueError('Invalid face count')
    if 'limit' in p and (type(p['limit']) is not int or not 1<=p['limit']<=10000): raise ValueError('Invalid limit')
    p.setdefault('limit',200)
    return p

def search(db,plan):
    p=validate(plan);conditions=['a.active=1'];args=[]
    if p.get('text'):
        tokens=re.findall(r'\w+',p['text'],re.UNICODE)
        if not tokens: raise ValueError('Enter search words')
        conditions.append('a.asset_id IN (SELECT asset_id FROM search_fts WHERE search_fts MATCH ?)')
        args.append(' AND '.join('"'+t+'"' for t in tokens))
    for name in p.get('people_all',[]):
        conditions.append("a.asset_id IN (SELECT p.asset_id FROM people p WHERE p.name=? COLLATE NOCASE AND p.source IN ('user_confirmed','apple_photos'))");args.append(name)
    for key,op in [('after','>='),('before','<')]:
        if key in p: conditions.append('a.created_at '+op+' ?');args.append(p[key])
    if 'favorite' in p: conditions.append('a.favorite=?');args.append(int(p['favorite']))
    if p.get('media') in ['photo','video']: conditions.append('a.media_type=?');args.append(1 if p['media']=='photo' else 2)
    if 'min_faces' in p: conditions.append('n.face_count>=?');args.append(p['min_faces'])
    if p.get('camera'): conditions.append("a.camera_model LIKE ? ESCAPE '\\'");args.append('%'+p['camera'].replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%')
    # Enrichment is invalidated by a source modification; stale face results never qualify.
    if 'min_faces' in p: conditions.append('n.source_modified_at IS a.modified_at')
    where=' AND '.join(conditions)
    source='assets a' + (' INDEXED BY sqlite_autoindex_assets_1' if p.get('people_all') or p.get('text') else '') + ' LEFT JOIN analysis n USING(asset_id)'
    start=time.perf_counter()
    total=db.execute('SELECT count(*) FROM '+source+' WHERE '+where,args).fetchone()[0]
    records=db.execute('''SELECT a.asset_id,a.created_at,a.width,a.height,a.favorite,a.media_type,a.camera_model,n.face_count,
      a.raw_json AS metadata_json,n.raw_json AS analysis_json,(SELECT group_concat(DISTINCT name) FROM people p WHERE p.asset_id=a.asset_id) AS people,
      (SELECT classification_json FROM semantic_metadata s WHERE s.asset_id=a.asset_id AND s.source_modified_at IS a.modified_at) AS semantic_json
      ,(SELECT group_concat(DISTINCT source) FROM people p WHERE p.asset_id=a.asset_id) AS people_sources
      FROM '''+source+' WHERE '+where+' ORDER BY a.created_at DESC,a.asset_id LIMIT ?',args+[p['limit']]).fetchall()
    return {'plan':p,'total_matches':total,'returned':len(records),'query_ms':round((time.perf_counter()-start)*1000,2),'results':[dict(r) for r in records]}

def plan_local(db,question,model='granite3.3:2b'):
    names=[r[0] for r in db.execute('SELECT DISTINCT name FROM people')]
    today=dt.datetime.now().astimezone().date().isoformat()
    # Resolve explicit filters deterministically; a small LLM must not invent dates or names.
    named=[name for name in names if re.search(r'(?<!\w)'+re.escape(name)+r'(?!\w)',question,re.I)]
    explicit={}
    if named: explicit['people_all']=named
    if re.search(r'\bfavou?rites?\b',question,re.I): explicit['favorite']=True
    if re.search(r'\bvideos?\b',question,re.I): explicit['media']='video'
    elif re.search(r'\bphotos?|pictures?\b',question,re.I): explicit['media']='photo'
    years=re.findall(r'\b(20\d{2}|19\d{2})\b',question)
    if len(years)==1:
        explicit['after']=years[0]+'-01-01';explicit['before']=str(int(years[0])+1)+'-01-01'
    days=re.search(r'(?:last|past)\s+(\d{1,3})\s+days?',question,re.I)
    if days:
        explicit['after']=(dt.date.fromisoformat(today)-dt.timedelta(days=int(days[1]))).isoformat()
        explicit['before']=(dt.date.fromisoformat(today)+dt.timedelta(days=1)).isoformat()
    face_match=re.search(r'(?:at least\s+)?(\d+|one|two|three|four|five|six)\s*(?:\+\s*)?faces?',question,re.I)
    if face_match:
        v=face_match[1].lower();explicit['min_faces']=int(v) if v.isdigit() else dict(one=1,two=2,three=3,four=4,five=5,six=6)[v]
    remaining=question.lower()
    for name in named: remaining=re.sub(r'(?<!\w)'+re.escape(name.lower())+r'(?!\w)',' ',remaining)
    remaining=re.sub(r'\b(give|me|show|find|all|photos|photo|pictures|picture|videos|video|of|with|and|both|please|favorite|favorites|favourite|favourites|from|in|the|last|past|days|day|at|least|one|two|three|four|five|six|faces|face)\b|\b\d+\b|[+.,?!]',' ',remaining)
    if explicit and not remaining.strip(): return validate(explicit)
    prompt='''Translate a photo search into one JSON object. No SQL. Allowed keys:
text: string with only content keywords (omit common request words), people_all: array of exact named people requested,
after: YYYY-MM-DD inclusive, before: YYYY-MM-DD exclusive, favorite: boolean, media: photo/video/any,
min_faces: integer, camera: string, limit: integer 1-10000.
Return ONLY the keys required by the user's words. Never add a date, limit, camera, or face count unless explicitly requested.
Examples:
User: photos of Riley and Jordan
JSON: {"people_all":["Riley","Jordan"]}
User: beach photos
JSON: {"text":"beach","media":"photo"}
User: videos from 2025
JSON: {"media":"video","after":"2025-01-01","before":"2026-01-01"}
User: favorite photos with at least four faces
JSON: {"favorite":true,"media":"photo","min_faces":4}
Omit filters not requested. "Riley and Jordan" means people_all includes BOTH; never put names in text.
Do not invent people labels or infer identities. Search only known metadata; do not claim to see photos.
Today: '''+today+'\nKnown confirmed names: '+json.dumps(names)+'\nUser search: '+question
    body=json.dumps({'model':model,'prompt':prompt,'stream':False,'format':'json','options':{'temperature':0,'num_predict':250,'num_ctx':2048},'keep_alive':'2m'}).encode()
    # Fixed loopback endpoint; no remote service and no library images sent.
    request=urllib.request.Request('http://127.0.0.1:11434/api/generate',data=body,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=90) as response: answer=json.load(response)
    planned=validate(json.loads(answer['response']))
    if named: planned['people_all']=named
    else: planned.pop('people_all',None)
    if 'favorite' not in explicit: planned.pop('favorite',None)
    if not years and not days and not re.search(r'\b(today|yesterday|week|month|year|january|february|march|april|may|june|july|august|september|october|november|december)\b',question,re.I):
        planned.pop('after',None);planned.pop('before',None)
    if not face_match: planned.pop('min_faces',None)
    if not re.search(r'iphone|camera|canon|nikon|sony|pixel|fujifilm|leica',question,re.I): planned.pop('camera',None)
    planned.pop('limit',None)
    planned.update(explicit)
    return validate(planned)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--base',type=pathlib.Path,default=BASE)
    subs=parser.add_subparsers(dest='command',required=True)
    subs.add_parser('sync');subs.add_parser('stats')
    p=subs.add_parser('search');p.add_argument('--plan',required=True)
    p=subs.add_parser('ask');p.add_argument('question');p.add_argument('--model',default='granite3.3:2b')
    p=subs.add_parser('save');p.add_argument('--name',required=True);p.add_argument('--plan',required=True);p.add_argument('--ids-json')
    p=subs.add_parser('collection');p.add_argument('id',type=int)
    args=parser.parse_args();db=connect(args.base)
    status=sync(db,args.base)
    if args.command in ['sync','stats']: result=status
    elif args.command=='search': result=search(db,json.loads(args.plan))
    elif args.command=='ask':
        start=time.perf_counter();result=search(db,plan_local(db,args.question,args.model));result['planner_seconds']=round(time.perf_counter()-start,2)
    elif args.command=='save':
        result=search(db,json.loads(args.plan))
        if args.ids_json:
            ids=json.loads(args.ids_json)
            if not isinstance(ids,list) or len(ids)>10000 or any(not isinstance(x,str) for x in ids): raise ValueError('Invalid result snapshot')
            found={r[0] for r in db.execute('SELECT asset_id FROM assets WHERE active=1')}
            if any(x not in found for x in ids): raise ValueError('Some results are no longer active; refresh search')
            result['results']=[{'asset_id':x} for x in dict.fromkeys(ids)];result['returned']=len(result['results'])
        with db:
            cursor=db.execute('INSERT INTO collections(name,query_json,created_at) VALUES(?,?,?)',(args.name,json.dumps(result['plan']),dt.datetime.now(dt.timezone.utc).isoformat()))
            cid=cursor.lastrowid
            db.executemany('INSERT INTO collection_items VALUES(?,?)',[(cid,r['asset_id']) for r in result['results']])
        result={'collection_id':cid,'name':args.name,'saved_count':result['returned'],'total_matches':result['total_matches'],'plan':result['plan']}
    elif args.command=='collection': result={'results':[dict(r) for r in db.execute('SELECT asset_id FROM collection_items WHERE collection_id=?',(args.id,))]}
    print(json.dumps(result));db.close()

if __name__=='__main__':
    try: main()
    except Exception as error: print(json.dumps({'error':str(error)}));sys.exit(1)
