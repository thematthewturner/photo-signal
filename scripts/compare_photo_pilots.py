#!/usr/bin/env python3
"""Build an unscored, deterministic A/B review of matching photo pilots."""
import argparse, hashlib, html, json, random
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('first',type=Path);p.add_argument('second',type=Path);a=p.parse_args()
def load(run):
 sample=json.loads((run/'sample.json').read_text())['items']
 preds={r['sample_id']:r for r in map(json.loads,(run/'predictions.jsonl').read_text().splitlines())}
 return sample,preds
s1,r1=load(a.first);s2,r2=load(a.second)
assert [(i['sample_id'],i['sha256']) for i in s1]==[(i['sample_id'],i['sha256']) for i in s2], 'Samples differ'
root=a.second.parents[2]; rng=random.Random(42);cards=[];key={}
for item in s1:
 sid=item['sample_id'];swap=rng.choice([False,True]);runs=[r1,r2] if not swap else [r2,r1]
 key[sid]={'A':str(a.first if not swap else a.second),'B':str(a.second if not swap else a.first)}
 panels=[]
 for label,records in zip(['A','B'],runs):
  record=records.get(sid,{});output=record.get('parsed_classification')
  panels.append('<section><h3>'+label+'</h3><pre>'+html.escape(json.dumps(output or {'status':record.get('status','missing')},indent=2,ensure_ascii=False))+'</pre></section>')
 rel='../../../'+item['relative_path']
 cards.append('<article><h2>'+sid+'</h2><img loading="lazy" src="'+html.escape(rel)+'"><div class="pair">'+''.join(panels)+'</div><label>Preferred: <select data-id="'+sid+'"><option value=""></option><option>A</option><option>B</option><option>Tie</option><option>Neither</option></select></label><textarea data-id="'+sid+'" placeholder="Unsupported claims, missed details, notes"></textarea></article>')
page='''<!doctype html><meta charset="utf-8"><title>Blind photo pilot comparison</title><style>body{font:16px system-ui;margin:30px;background:#f4f5f8}article{padding:24px;margin-bottom:24px;background:white;border-radius:12px}img{height:280px;max-width:100%;object-fit:contain}.pair{display:grid;grid-template-columns:1fr 1fr;gap:24px}pre{white-space:pre-wrap;font-size:13px}textarea{display:block;width:95%;margin-top:12px;height:65px}button{padding:12px;margin-bottom:20px}</style><h1>Photo classification: blind A/B review</h1><p>Same 30 images. A/B order varies per photo. Scores are blank. Changes require downloading to persist.</p><button onclick="save()">Download evaluation JSON</button><button onclick="reveal()">Reveal model identities</button><div id="key"></div>'''+''.join(cards)+'''<script>let dirty=false;document.addEventListener('input',()=>dirty=true);window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue=''}});const identities='''+json.dumps(key)+''';function save(){let values=[...document.querySelectorAll('select')].map(s=>({sample_id:s.dataset.id,preferred:s.value||null,notes:document.querySelector('textarea[data-id="'+s.dataset.id+'"]').value||null}));let blob=new Blob([JSON.stringify({scores:values},null,2)],{type:'application/json'});let a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='comparison-evaluation.json';a.click();dirty=false}function reveal(){document.getElementById('key').textContent=JSON.stringify(identities)}</script>'''
(a.second/'comparison.html').write_text(page)
(a.second/'comparison-key.json').write_text(json.dumps(key,indent=2))
print(a.second/'comparison.html')
