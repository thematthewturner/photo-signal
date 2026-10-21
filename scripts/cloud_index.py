#!/usr/bin/env python3
"""Resumable monthly Fireworks index. Credentials and person labels stay local."""
import argparse, base64, concurrent.futures, datetime as dt, fcntl, hashlib, json, os
import signal, sqlite3, statistics, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path
import jsonschema
import catalog

os.umask(0o077)
BASE = Path.home() / 'Library/Application Support/PhotoSignal'
MODEL = 'accounts/fireworks/models/glm-5p3-flash'
RATES = (.15, .03, .5)  # USD / million: input, cached input, output; calculated, not invoice
RESERVE = (8192 * RATES[0] + 4096 * RATES[2]) / 1e6 + .001
STOP = False


def utc(): return dt.datetime.now(dt.timezone.utc).isoformat()
def digest(b): return hashlib.sha256(b).hexdigest()
def read(p, default=None):
    try: return json.loads(p.read_text())
    except (OSError, ValueError): return default
def save(p, data):
    tmp = p.with_suffix(p.suffix + '.tmp')
    tmp.write_text(json.dumps(data, indent=2)); tmp.replace(p)
def month_paths(month):
    dt.datetime.strptime(month + '-01', '%Y-%m-%d')
    return BASE / 'cloud-index' / month, BASE / 'sandbox-cache' / month
def contract(name):
    direct = Path(__file__).parent / name
    return direct if direct.exists() else Path(__file__).resolve().parents[1] / 'contracts' / name
def open_run(folder):
    db = sqlite3.connect(folder / 'run.sqlite', timeout=30); db.row_factory = sqlite3.Row
    db.executescript('''PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS jobs(job_id TEXT PRIMARY KEY,asset_id TEXT,sample_id TEXT,
      input_sha256 TEXT,source_modified_at TEXT,path TEXT,status TEXT,classification_json TEXT,error TEXT,
      active INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE IF NOT EXISTS attempts(id INTEGER PRIMARY KEY,job_id TEXT,status TEXT,started TEXT,
      finished TEXT,wall_seconds REAL,input_tokens INTEGER,output_tokens INTEGER,cached_tokens INTEGER,
      reasoning_tokens INTEGER,cost REAL,reservation REAL,error TEXT,response_json TEXT);
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);
    CREATE INDEX IF NOT EXISTS jobs_input_hash ON jobs(input_sha256);
    ''')
    if 'active' not in {r[1] for r in db.execute('PRAGMA table_info(jobs)')}:
        db.execute('ALTER TABLE jobs ADD COLUMN active INTEGER NOT NULL DEFAULT 1'); db.commit()
    for column in ('analysis_input_sha256','reuse_source'):
        if column not in {r[1] for r in db.execute('PRAGMA table_info(jobs)')}:
            db.execute('ALTER TABLE jobs ADD COLUMN '+column+' TEXT')
    db.execute('CREATE INDEX IF NOT EXISTS jobs_asset_version ON jobs(asset_id,source_modified_at)');db.commit()
    return db


def search_text(c):
    # Search visible content, not uncertainty explanations (which can mention absent objects).
    parts = [c['caption'], *c['search_phrases'], *c['scene']['settings'], *c['scene']['background_elements'],
             *c['scene']['lighting'], *c['scene']['weather_visible'], c['image_type']]
    for field in ('activities', 'objects', 'animals'):
        parts += [v['label'] for v in c[field]]
    parts += [v['text'] for v in c['visible_text'] if v['legibility'] == 'clear']
    return ' '.join(parts)


def import_result(db, job, c, prompt_hash):
    with db:
        db.execute('''INSERT OR REPLACE INTO semantic_metadata VALUES(?,?,?,?,?,?,?,?)''',
                   (job['asset_id'], job['source_modified_at'], MODEL, (job['analysis_input_sha256'] if 'analysis_input_sha256' in job.keys() and job['analysis_input_sha256'] else job['input_sha256']), prompt_hash,
                    json.dumps(c), search_text(c), utc()))
        catalog.refresh_search_asset(db, job['asset_id'])


def people_worker(month):
    folder, source = month_paths(month)
    import osxphotos
    rows = [json.loads(s) for s in (source / 'manifest.jsonl').read_text().splitlines() if s.strip()]
    ids = {r['asset_id'].split('/')[0].upper(): r['asset_id'] for r in rows}
    library_file=BASE/'apple-people-library.json'
    library=read(library_file,{})
    if library.get('status')!='complete' or time.time()-library_file.stat().st_mtime>7*86400:
        photos = osxphotos.PhotosDB(_skip_searchinfo=True)
        associations={}
        for photo in photos.photos(images=True,movies=False):
            names=[n for n in photo.persons if n and n!='_UNKNOWN_' and not n.startswith('_')]
            if names: associations[photo.uuid.upper()]=names
        library={'status':'complete','read_at':utc(),'associations':associations}
        save(library_file,library)
    result={aid:library['associations'][uuid] for uuid,aid in ids.items() if uuid in library['associations']}
    save(folder / 'apple-people.json', {'status': 'complete', 'read_at': utc(), 'assets_checked': len(rows),
                                      'named_assets': len(result), 'associations': result,
                                      'manifest_sha256': digest((source/'manifest.jsonl').read_bytes()),
                                      'source': 'Apple Photos existing People labels; not manual confirmation'})


def refresh_people(folder, month, db, report):
    report(phase='apple_people', message='Reading existing Apple People associations locally…')
    cached = read(folder / 'apple-people.json', {})
    manifest_hash = digest((BASE/'sandbox-cache'/month/'manifest.jsonl').read_bytes())
    if cached.get('manifest_sha256') != manifest_hash: cached = {}
    if cached.get('status') == 'unavailable': return {k:v for k,v in cached.items() if k!='associations'}
    if cached.get('status') != 'complete':
        with (folder / 'people-worker.log').open('a') as log:
            process = subprocess.Popen([sys.executable, __file__, '--month', month, '--people-worker'], stdout=log, stderr=log)
            tick = time.monotonic()
            while process.poll() is None:
                report(phase='apple_people', message='Reading Apple People locally; no image inference yet.')
                if time.monotonic() - tick > 600 or STOP:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
                    break
                time.sleep(1)
        cached = read(folder / 'apple-people.json', {})
    if cached.get('status') != 'complete':
        unavailable={'status':'unavailable','named_assets':0,'manifest_sha256':manifest_hash,'message':'Apple People import failed or timed out; see people-worker.log. Remove this unavailable checkpoint to retry. No names inferred.'}
        save(folder/'apple-people.json',unavailable)
        return unavailable
    with db:
        for row in [json.loads(s) for s in (BASE / 'sandbox-cache' / month / 'manifest.jsonl').read_text().splitlines() if s.strip()]:
            aid = row['asset_id']
            db.execute("DELETE FROM people WHERE asset_id=? AND source='apple_photos'", (aid,))
            for name in cached['associations'].get(aid, []):
                db.execute('INSERT OR REPLACE INTO people VALUES(?,?,?,?)', (aid, name, 'apple_photos', cached['read_at']))
            catalog.refresh_search_asset(db, aid)
    return {k: v for k, v in cached.items() if k != 'associations'}


def request_image(job, prompt, schema, secret):
    tick = time.monotonic(); response = {}; error = None; ambiguous = False
    try:
        data = Path(job['path']).read_bytes()
        if digest(data) != job['input_sha256']: raise ValueError('Preview hash mismatch')
        payload = {'model': MODEL, 'temperature': 0, 'reasoning_effort': 'low', 'max_tokens': 4096,
                   'prompt_truncate_len': 8192,
                   'messages': [{'role': 'system', 'content': 'You are a JSON-only image classifier. Output one JSON object and nothing else.'},
                                {'role': 'user', 'content': [{'type': 'text', 'text': prompt},
                                 {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(data).decode()}}]}],
                   'response_format': {'type': 'json_schema', 'json_schema': {'name': 'PhotoClassification', 'schema': schema}}}
        req = urllib.request.Request('https://api.fireworks.ai/inference/v1/chat/completions',
                                     data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + secret})
        try:
            with urllib.request.urlopen(req, timeout=90) as reply: response = json.load(reply)
        except urllib.error.HTTPError as exc:
            error = 'HTTP ' + str(exc.code); ambiguous = True
        except Exception as exc:
            error = type(exc).__name__; ambiguous = True
    except Exception as exc:
        error = str(exc)[:200]
    usage = response.get('usage', {}); inp = usage.get('prompt_tokens'); out = usage.get('completion_tokens')
    cache = usage.get('prompt_tokens_details', {}).get('cached_tokens', 0) or 0
    reasoning = usage.get('completion_tokens_details', {}).get('reasoning_tokens')
    cost = ((inp-cache)*RATES[0]+cache*RATES[1]+out*RATES[2])/1e6 if inp is not None and out is not None else None
    parsed = None
    if not error:
        try:
            choice = response['choices'][0]
            if choice.get('finish_reason') != 'stop': raise ValueError('Incomplete response: ' + str(choice.get('finish_reason')))
            if inp is None or out is None: ambiguous = True; raise ValueError('Missing token usage')
            if inp >= 8192: raise ValueError('Input cap reached; response excluded')
            parsed = json.loads(choice['message']['content']); jsonschema.Draft202012Validator(schema).validate(parsed)
        except Exception as exc: error = str(exc)[:400]; parsed = None
    return {'response': response, 'classification': parsed, 'error': error, 'ambiguous': ambiguous,
            'input': inp, 'output': out, 'cache': cache, 'reasoning': reasoning, 'cost': cost, 'seconds': time.monotonic()-tick}


def totals(db):
    rows = db.execute('SELECT * FROM attempts').fetchall()
    return {'requests': len(rows), 'input_tokens': sum(r['input_tokens'] or 0 for r in rows),
            'output_tokens': sum(r['output_tokens'] or 0 for r in rows),
            'cached_tokens': sum(r['cached_tokens'] or 0 for r in rows),
            'reasoning_tokens': sum(r['reasoning_tokens'] or 0 for r in rows),
            'calculated_usd': sum(r['cost'] or 0 for r in rows),
            'reserved_usd': sum(r['reservation'] for r in rows if r['cost'] is None),
            'usage_unknown_requests': sum(r['input_tokens'] is None for r in rows if r['status'] != 'running')}


def shared_results(pipeline, hashes=None):
    """Read prior durable jobs across months; never resubmit ambiguous image bytes."""
    results = {}
    for folder in sorted((BASE/'cloud-index').glob('*')):
        if read(folder/'config.json', {}).get('pipeline_sha256') != pipeline: continue
        if not (folder/'run.sqlite').exists(): continue
        db = sqlite3.connect((folder/'run.sqlite').as_uri()+'?mode=ro', uri=True)
        try:
            canonical="coalesce(analysis_input_sha256,input_sha256)" if 'analysis_input_sha256' in {r[1] for r in db.execute('PRAGMA table_info(jobs)')} else 'input_sha256'
            query="SELECT input_sha256,status,classification_json,"+canonical+" FROM jobs WHERE status IN ('success','unknown','running','failed')"
            queries=[(query,[])] if hashes is None else [(query+" AND input_sha256 IN ("+','.join('?' for _ in chunk)+")",chunk) for chunk in [list(hashes)[i:i+500] for i in range(0,len(hashes),500)]]
            matched = (row for query,args in queries for row in db.execute(query,args))
            for ih, status, payload, analyzed in matched:
                if not ih: continue
                if status == 'success' and payload: results[ih] = ('success', payload, analyzed)
                elif ih not in results: results[ih] = ('failed' if status=='failed' else 'unknown', None, analyzed)
        finally: db.close()
    return results

def version_results(pipeline, assets):
    results={}; assets=list(assets)
    for folder in sorted((BASE/'cloud-index').glob('*')):
        if read(folder/'config.json',{}).get('pipeline_sha256')!=pipeline or not (folder/'run.sqlite').exists():continue
        db=sqlite3.connect((folder/'run.sqlite').as_uri()+'?mode=ro',uri=True)
        try:
            canonical="coalesce(analysis_input_sha256,input_sha256)" if 'analysis_input_sha256' in {r[1] for r in db.execute('PRAGMA table_info(jobs)')} else 'input_sha256'
            for i in range(0,len(assets),500):
                chunk=assets[i:i+500]
                query="SELECT asset_id,source_modified_at,status,classification_json,"+canonical+" FROM jobs WHERE status IN ('success','unknown','running','failed') AND asset_id IN ("+','.join('?' for _ in chunk)+')'
                for aid,modified,status,payload,analyzed in db.execute(query,chunk):
                    key=(aid,modified)
                    if status=='success' and payload:results[key]=('success',payload,analyzed,str(folder))
                    elif key not in results:results[key]=('failed' if status=='failed' else 'unknown',None,analyzed,str(folder))
        finally:db.close()
    return results

def global_spend():
    cost = reserved = 0
    for path in (BASE/'cloud-index').glob('*/run.sqlite'):
        db = sqlite3.connect(path.as_uri()+'?mode=ro', uri=True)
        try:
            row=db.execute('SELECT coalesce(sum(cost),0),coalesce(sum(CASE WHEN cost IS NULL THEN reservation ELSE 0 END),0) FROM attempts').fetchone()
            cost+=row[0];reserved+=row[1]
        finally: db.close()
    return cost, reserved

def run(month, budget, concurrency, retry_failed=False, max_new=None, global_budget=None):
    global STOP
    folder, source = month_paths(month); folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    global_lock = (BASE / 'cloud-index' / 'global-worker.lock').open('a')
    try: fcntl.flock(global_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('Another month is already indexing')
    lock = (folder / 'worker.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('This month already has an active worker')
    (folder / 'pause').unlink(missing_ok=True)  # clear only the previous pause, before new work
    if not (source / 'summary.json').exists(): raise RuntimeError('Export must complete before cloud indexing')
    db = open_run(folder); cat = catalog.connect(); started = time.monotonic()
    initial_global = global_spend() if global_budget is not None else (0,0)
    initial_month = totals(db)
    other_spend = (initial_global[0]-initial_month['calculated_usd'],initial_global[1]-initial_month['reserved_usd'])
    old = read(folder / 'progress.json', {})
    active_prior = old.get('active_seconds', 0)
    state = {'month': month, 'model': MODEL, 'budget_usd': budget, 'concurrency': concurrency,
             'run_started_at': utc(), 'first_started_at': old.get('first_started_at', utc()),
             'phase': 'preparing', 'people': old.get('people', {}), 'message': 'Preparing monthly queue',
             'cost_basis': 'API-reported tokens × published rates; not invoice charges',
             'rates_per_million': {'input': RATES[0], 'cached_input': RATES[1], 'output': RATES[2]},
             'network': 'Rendered previews and the classification prompt go to Fireworks. Apple People labels and library metadata are not sent.'}
    batch_new = reused = 0
    phase_since = time.monotonic()
    phase_totals = old.get('phase_seconds', {})
    def report(**changes):
        nonlocal phase_since
        phase = state['phase']
        if changes.get('phase', phase) != phase:
            phase_totals[phase] = phase_totals.get(phase, 0) + time.monotonic() - phase_since
            phase_since = time.monotonic()
        state.update(changes); state.update(totals(db)); state['heartbeat_at'] = utc()
        state['phase_seconds'] = dict(phase_totals)
        state['phase_seconds'][state['phase']] = phase_totals.get(state['phase'], 0) + time.monotonic() - phase_since
        state['export_seconds'] = read(source / 'export-progress.json', {}).get('elapsed_seconds')
        state['icloud_recovery'] = read(source / 'download-progress.json', {})
        state['active_seconds'] = active_prior + time.monotonic()-started
        state['session_seconds'] = time.monotonic()-started
        counts = {r[0]: r[1] for r in db.execute('SELECT status,count(*) FROM jobs WHERE active=1 GROUP BY status')}
        state['batch_new_requests'] = batch_new
        state['reused_results'] = reused
        state['batch_limit'] = max_new
        state['global_budget_usd'] = global_budget
        state['counts'] = counts; state['total'] = sum(counts.values())
        elapsed = [r[0] for r in db.execute('SELECT wall_seconds FROM attempts WHERE wall_seconds IS NOT NULL')]
        state['median_request_seconds'] = statistics.median(elapsed) if elapsed else None
        state['request_seconds_total'] = sum(elapsed)
        state['eta_seconds'] = counts.get('waiting', 0)*statistics.mean(elapsed)/concurrency if elapsed else None
        state['recent'] = [dict(r) for r in db.execute('SELECT j.sample_id,j.asset_id,j.status,j.error,a.wall_seconds,a.input_tokens,a.output_tokens,a.cost FROM jobs j LEFT JOIN attempts a ON a.id=(SELECT max(id) FROM attempts WHERE job_id=j.job_id) WHERE j.active=1 ORDER BY coalesce(a.id,0) DESC LIMIT 16')]
        save(folder / 'progress.json', state)
    try:
        with db:
            db.execute("UPDATE jobs SET status='unknown',error='Interrupted in-flight request; not automatically charged again' WHERE status='running'")
            db.execute("UPDATE attempts SET status='unknown',error='Worker interrupted; usage unknown' WHERE status='running'")
            if retry_failed: db.execute("UPDATE jobs SET status='waiting',error=NULL WHERE status='failed'")
        prompt = contract('photo-classification-prompt.txt').read_text()
        schema_bytes = contract('photo-classification.schema.json').read_bytes(); schema = json.loads(schema_bytes)
        ph = digest(prompt.encode()); pipeline = digest((MODEL+ph+digest(schema_bytes)).encode())
        config = {'month': month, 'model': MODEL, 'pipeline_sha256': pipeline, 'prompt_sha256': ph,
                  'schema_sha256': digest(schema_bytes), 'budget_usd': budget, 'concurrency': concurrency,
                  'max_input_tokens': 8192, 'max_output_tokens': 4096, 'preview_size_folder': 'images-768',
                  'authorization': 'User-requested Photos indexing with app telemetry', 'rates_per_million': RATES}
        prior = read(folder / 'config.json')
        if prior and prior['pipeline_sha256'] != pipeline: raise RuntimeError('Changed model/prompt/schema requires a new run folder')
        save(folder / 'config.json', config)
        rows = [json.loads(s) for s in (source / 'manifest.jsonl').read_text().splitlines() if s.strip()]
        if not rows: raise RuntimeError('Photos returned an empty export. Check Photos authorization/library access; no API requests sent.')
        with cat, db:
            db.execute('UPDATE jobs SET active=0')
            for row in rows:
                aid = row['asset_id']; rel = row.get('files', {}).get('768'); path = source / rel if rel else None
                if not cat.execute('SELECT 1 FROM assets WHERE asset_id=?',(aid,)).fetchone(): catalog.upsert_asset(cat, row)
                else: cat.execute('UPDATE assets SET modified_at=?,created_at=?,width=?,height=? WHERE asset_id=?', (row.get('modified_at'),row.get('created_at'),row.get('width'),row.get('height'),aid))
                catalog.refresh_search_asset(cat, aid)
                ih = digest(path.read_bytes()) if path and path.exists() else ''
                jid = digest((aid+str(row.get('modified_at'))+ih+pipeline).encode())
                db.execute('INSERT OR IGNORE INTO jobs(job_id,asset_id,sample_id,input_sha256,source_modified_at,path,status,classification_json,error) VALUES(?,?,?,?,?,?,?,?,?)',(jid, aid, row['sample_id'], ih, row.get('modified_at'), str(path) if path else '', 'waiting' if ih else 'unavailable', None, 'No local preview' if not ih else None))
                db.execute('UPDATE jobs SET active=1 WHERE job_id=?',(jid,))
        hashes = {r[0] for r in db.execute('SELECT input_sha256 FROM jobs WHERE active=1 AND input_sha256 != \'\'')}
        shared = shared_results(pipeline,hashes)
        versions = version_results(pipeline,{r[0] for r in db.execute("SELECT asset_id FROM jobs WHERE active=1")})
        # Reuse compatible catalog-only imports as well as durable monthly jobs.
        cat.execute('CREATE INDEX IF NOT EXISTS semantic_input_hash ON semantic_metadata(input_sha256,model,prompt_sha256)');cat.commit()
        for ih in hashes:
            for saved in cat.execute('SELECT classification_json FROM semantic_metadata WHERE input_sha256=? AND model=? AND prompt_sha256=?',(ih,MODEL,ph)):
                try: jsonschema.validate(json.loads(saved[0]),schema)
                except (ValueError,jsonschema.ValidationError): continue
                shared[ih]=('success',saved[0],ih);break
        if retry_failed:
            shared = {k:v for k,v in shared.items() if v[0]!='failed'}
            versions = {k:v for k,v in versions.items() if v[0]!='failed'}
        report(export=read(source / 'summary.json', {}))
        state['people'] = refresh_people(folder, month, cat, report)
        report(phase='indexing', message='Starting GLM caption and tag requests')
        secret = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'photosignal-fireworks', '-w'], capture_output=True, text=True, check=True).stdout.strip()
        if not secret: raise RuntimeError('Fireworks Keychain credential is empty')
        # Repair a crash after job commit but before catalog commit, without repeating inference.
        for job in db.execute("SELECT * FROM jobs WHERE active=1 AND status='success'").fetchall(): import_result(cat, job, json.loads(job['classification_json']), ph)
        pause_reason = None
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = {}
            while True:
                if STOP or (folder / 'pause').exists(): pause_reason = 'paused'
                while len(futures) < concurrency and not pause_reason:
                    job = db.execute("SELECT * FROM jobs WHERE active=1 AND status='waiting' ORDER BY sample_id LIMIT 1").fetchone()
                    if not job: break
                    cached = versions.get((job['asset_id'],job['source_modified_at']))
                    hashed = shared.get(job['input_sha256'])
                    if not cached or (cached[0]!='success' and hashed and hashed[0]=='success'): cached=hashed
                    if cached:
                        with db: db.execute('UPDATE jobs SET status=?,classification_json=?,analysis_input_sha256=?,reuse_source=?,error=? WHERE job_id=?', (cached[0],cached[1],cached[2],cached[3] if len(cached)>3 else 'matching preview hash',None if cached[0]=='success' else 'Prior failed/interrupted request for this photo version; manual review required',job['job_id']))
                        job=db.execute('SELECT * FROM jobs WHERE job_id=?',(job['job_id'],)).fetchone()
                        if cached[0]=='success': import_result(cat,job,json.loads(cached[1]),ph); reused+=1
                        continue
                    if any(other[0]['input_sha256']==job['input_sha256'] for other in futures.values()): break
                    if max_new is not None and batch_new >= max_new: pause_reason='batch_complete';break
                    if global_budget is not None:
                        current = totals(db)
                        spent, reserved = other_spend[0]+current['calculated_usd'], other_spend[1]+current['reserved_usd']
                        if spent+reserved+RESERVE>global_budget: pause_reason='budget_paused';break
                    usage = totals(db)
                    if usage['calculated_usd'] + usage['reserved_usd'] + RESERVE > budget:
                        pause_reason = 'budget_paused'; break
                    with db:
                        db.execute("UPDATE jobs SET status='running' WHERE job_id=?", (job['job_id'],))
                        attempt = db.execute('INSERT INTO attempts(job_id,status,started,reservation) VALUES(?,?,?,?)', (job['job_id'], 'running', utc(), RESERVE)).lastrowid
                    batch_new += 1
                    futures[pool.submit(request_image, dict(job), prompt, schema, secret)] = (dict(job), attempt)
                report(phase='pausing' if pause_reason else 'indexing', message='Finishing active requests before pause' if pause_reason else 'GLM is classifying previews; each result is checkpointed')
                if not futures: break
                done, _ = concurrent.futures.wait(futures, timeout=1, return_when=concurrent.futures.FIRST_COMPLETED)
                for future in done:
                    job, attempt = futures.pop(future); result = future.result()
                    status = 'success' if result['classification'] is not None else ('unknown' if result['ambiguous'] else 'failed')
                    with db:
                        db.execute('UPDATE attempts SET status=?,finished=?,wall_seconds=?,input_tokens=?,output_tokens=?,cached_tokens=?,reasoning_tokens=?,cost=?,error=?,response_json=? WHERE id=?',
                                   (status, utc(), result['seconds'], result['input'], result['output'], result['cache'], result['reasoning'], result['cost'], result['error'], json.dumps(result['response']), attempt))
                        db.execute('UPDATE jobs SET status=?,classification_json=?,error=? WHERE job_id=?', (status, json.dumps(result['classification']) if result['classification'] else None, result['error'], job['job_id']))
                    if status in ('success','unknown','failed'): shared[job['input_sha256']] = (status,json.dumps(result['classification']) if result['classification'] else None,job['input_sha256'])
                    versions[(job['asset_id'],job['source_modified_at'])]=(status,json.dumps(result['classification']) if result['classification'] else None,job['input_sha256'],str(folder))
                    if status == 'success': import_result(cat, job, result['classification'], ph)
                    if result['ambiguous']: pause_reason = 'attention_required'
                    print(job['sample_id'] + ': ' + status, flush=True)
        counts = {r[0]: r[1] for r in db.execute('SELECT status,count(*) FROM jobs WHERE active=1 GROUP BY status')}
        final = pause_reason or ('complete_with_gaps' if state['people'].get('status') != 'complete' or any(counts.get(k) for k in ('failed', 'unknown', 'unavailable')) else 'complete')
        report(phase=final, message='Run saved. Resume skips completed photos.' if pause_reason else month+' pass finished. All results and usage are saved locally.')
    except Exception as exc:
        report(phase='failed', message=type(exc).__name__ + ': ' + str(exc)[:300]); raise
    finally:
        cat.close(); db.close(); lock.close(); global_lock.close()


def main():
    global STOP
    p = argparse.ArgumentParser(); p.add_argument('--month', default='2026-10'); p.add_argument('--budget', type=float, default=2)
    p.add_argument('--max-new',type=int); p.add_argument('--global-budget',type=float)
    p.add_argument('--concurrency', type=int, default=2); p.add_argument('--retry-failed', action='store_true'); p.add_argument('--people-worker', action='store_true')
    a = p.parse_args()
    if (a.max_new is not None and a.max_new<1) or (a.global_budget is not None and a.global_budget<=0): p.error('Positive batch size and global budget required')
    if a.budget <= 0 or a.concurrency not in (1, 2, 3, 4): p.error('Positive budget and concurrency 1–4 required')
    def stop(*_):
        global STOP
        STOP = True
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    if a.people_worker: people_worker(a.month)
    else: run(a.month, a.budget, a.concurrency, a.retry_failed, a.max_new, a.global_budget)


if __name__ == '__main__': main()
