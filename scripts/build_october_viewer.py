#!/usr/bin/env python3
"""Create a private, self-contained viewer from the completed October SQL snapshot."""
import base64, hashlib, json, os, sqlite3, io, argparse, datetime, calendar, fcntl
from PIL import Image
from pathlib import Path
os.umask(0o077)
BASE = Path.home() / 'Library/Application Support/PhotoSignal'


def build(month):
    first=datetime.date.fromisoformat(month+"-01")
    if first.strftime("%Y-%m") != month: raise ValueError("Invalid month")
    source = BASE / 'sandbox-cache' / month
    run = sqlite3.connect((BASE / 'cloud-index' / month / 'run.sqlite').as_uri()+'?mode=ro', uri=True)
    run.row_factory = sqlite3.Row
    catalog = sqlite3.connect((BASE / 'catalog.sqlite').as_uri()+'?mode=ro', uri=True)
    catalog.row_factory = sqlite3.Row
    photos = []
    for job in run.execute("SELECT * FROM jobs WHERE active=1 AND status='success' ORDER BY sample_id"):
        asset = catalog.execute('SELECT * FROM assets WHERE asset_id=? AND active=1', (job['asset_id'],)).fetchone()
        meta = catalog.execute('SELECT * FROM semantic_metadata WHERE asset_id=?', (job['asset_id'],)).fetchone()
        if not asset or not meta or meta['source_modified_at'] != asset['modified_at']: continue
        blob = Path(job['path']).read_bytes()
        if hashlib.sha256(blob).hexdigest() != job['input_sha256']: raise ValueError('Preview hash mismatch')
        people = [dict(p) for p in catalog.execute('SELECT DISTINCT name,source FROM people WHERE asset_id=? ORDER BY name', (job['asset_id'],))]
        c = json.loads(meta['classification_json'])
        photos.append(dict(id=job['asset_id'], sample=job['sample_id'], date=asset['created_at'],
                           favorite=bool(asset['favorite']), width=asset['width'], height=asset['height'],
                           camera=asset['camera_model'], people=people, classification=c,
                           thumbnail='data:image/jpeg;base64,'+base64.b64encode(blob).decode(),
                           search=meta['search_text'], input_sha256=meta['input_sha256']))
    months=sorted([p.parent.name for p in (BASE/'cloud-index').glob('????-??/run.sqlite')],reverse=True)
    data = dict(month=month, months=months, timezone='America/New_York', photos=photos,
                snapshot=hashlib.sha256(''.join(p['id']+p['input_sha256'] for p in photos).encode()).hexdigest())
    template_path=Path(__file__).with_name('october.html')
    if not template_path.exists(): template_path=Path(__file__).resolve().parents[1]/'web/october.html'
    template = template_path.read_text()
    label=first.strftime('%B %Y'); short=first.strftime('%B')
    template=template.replace('October 2026',label).replace('October',short).replace('2026-10-01',month+'-01').replace('2026-10-31',month+'-'+str(calendar.monthrange(first.year,first.month)[1])).replace('01 — 31 OCT, 2026',f"01 — {calendar.monthrange(first.year,first.month)[1]} {first.strftime('%b').upper()}, {first.year}")
    if template.count('__PHOTO_DATA__') != 1: raise ValueError('Expected exactly one data placeholder')
    payload = json.dumps(data, ensure_ascii=False).replace('<', r'\u003c').replace('\u2028',r'\u2028').replace('\u2029',r'\u2029')
    folder = BASE / 'october-viewer'; folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    html=template.replace('__PHOTO_DATA__',payload)
    review=[]
    for p in photos:
        image=Image.open(io.BytesIO(base64.b64decode(p['thumbnail'].split(',',1)[1]))).convert('RGB')
        image.thumbnail((384,384))
        out=io.BytesIO(); image.save(out,format='JPEG',quality=82)
        review.append(dict(id=p['id'],date=p['date'],favorite=p['favorite'],caption=p['classification']['caption'],quality=p['classification']['quality'],preview='data:image/jpeg;base64,'+base64.b64encode(out.getvalue()).decode()))
    (folder/'curation-data.json.tmp').write_text(json.dumps(dict(snapshot=data['snapshot'],photos=review)))
    (folder/'curation-data.json.tmp').replace(folder/'curation-data.json')
    (folder/'allowed-assets.json.tmp').write_text(json.dumps([p['id'] for p in photos]))
    (folder/'allowed-assets.json.tmp').replace(folder/'allowed-assets.json')
    (folder/'index.html.tmp').write_text(html)
    (folder/'index.html.tmp').replace(folder/'index.html')
    (folder/'current-month.txt').write_text(month)
    catalog.close();run.close()
    print(json.dumps({'output':str(folder/'index.html'),'photos':len(photos),'bytes':(folder/'index.html').stat().st_size}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--month',default=datetime.date.today().strftime('%Y-%m'));args=parser.parse_args()
    folder=BASE/'october-viewer';folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (folder/'build.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        build(args.month)
