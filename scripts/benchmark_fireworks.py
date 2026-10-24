#!/usr/bin/env python3
"""Fireworks pilot; credentials stay in Keychain and process memory only."""
import argparse,base64,hashlib,importlib.util,json,os,shutil,statistics,subprocess,time,urllib.request,urllib.error
from pathlib import Path
from datetime import datetime,timezone
import jsonschema
ROOT=Path.home()/'Documents/PhotoSignal-Sandbox/2026-09'
SOURCE=ROOT/'results/haiku-5.5/20261018T225131Z'
MODEL='accounts/fireworks/models/glm-5p3-flash'
RATES={'glm-5p3-flash':(.15,.03,.5),'deepseek-v4p1-flash':(.30,.006,1.20),'qwen3p8-max':(2,.25,6),'inkling':(1,.17,4.05)}
def now():return datetime.now(timezone.utc).isoformat()
def sha(b):return hashlib.sha256(b).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def append(p,v):
 with p.open('a') as f:f.write(json.dumps(v)+'\n');f.flush()
def rows(p):return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []
def main():
 global MODEL
 parser=argparse.ArgumentParser();parser.add_argument('--run-dir',type=Path);parser.add_argument('--model',choices=RATES,default='glm-5p3-flash');parser.add_argument('--budget',type=float,default=1);args=parser.parse_args()
 MODEL='accounts/fireworks/models/'+args.model
 input_rate,cache_rate,output_rate=RATES[args.model]
 reservation=(8192*input_rate+4096*output_rate)/1e6+.001
 run=args.run_dir or Path.home()/'Library/Application Support/PhotoSignal/fireworks-runs'/(args.model+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));run.mkdir(parents=True,exist_ok=True)
 for name in ['sample.json','asset-map.json','prompt.txt','classification.schema.json']:
  if not (run/name).exists():shutil.copy2(SOURCE/name,run/name)
 spec=importlib.util.spec_from_file_location('contract',SOURCE/'run_benchmark.py');helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
 sample=json.loads((run/'sample.json').read_text());schema=json.loads((run/'classification.schema.json').read_text());prompt=(run/'prompt.txt').read_text();validator=jsonschema.Draft202012Validator(schema)
 # Retrieve into memory: never print it, save it, put it in arguments, or include it in logs.
 secret=subprocess.run(['/usr/bin/security','find-generic-password','-s','photosignal-fireworks','-w'],capture_output=True,text=True,check=True).stdout.strip()
 if not secret:raise RuntimeError('Empty Keychain credential')
 config= json.loads((run/'config.json').read_text()) if (run/'config.json').exists() else {'run_id':run.name,'start_utc':now(),'model_requested':MODEL,'provider':'Fireworks serverless','inference_location':'remote','authorization':'User requested benchmark and saved API key after 30-photo/$1 scope was stated','prompt_sha256':sha(prompt.encode()),'schema_sha256':sha((run/'classification.schema.json').read_bytes()),'concurrency':1,'model_settings':{'temperature':0,'max_tokens':4096,'prompt_truncate_len':8192,'reasoning_effort':'low','response_format':'json_schema'},'image_preprocessing':'Unchanged JPEG bytes; no manifest or identifying paths submitted','pricing':{'input_per_million':input_rate,'cached_input_per_million':cache_rate,'output_per_million':output_rate,'url':'https://fireworks.ai/models/fireworks/'+args.model,'checked_date':'2026-10-18'},'budget_usd':args.budget,'per_attempt_reservation_usd':reservation,'budget_method':'Reserve cost of 8192 input + 4096 output tokens plus $0.001 before each request. Input cap enforced by prompt_truncate_len=8192; output cap 4096. Unknown-cost attempts retain reservation. Three runs budgeted at $0.33 each. No automatic network retries.','comparison_differences':['Direct REST instead of subscription CLI','Schema-constrained decoding','temperature 0; 4096 output-token cap; low reasoning requested','prompt_truncate_len=8192; stop if this cap is reached'],'status':'running'}
 save(run/'config.json',config)
 done={r['sample_id'] for r in rows(run/'predictions.jsonl')};stop=False
 for item in sample['items']:
  sid=item['sample_id']
  if sid in done:continue
  cache=Path.home()/'Library/Application Support/PhotoSignal/benchmark-cache'
  cache.mkdir(parents=True,exist_ok=True)
  cached=cache/(sid+'-fireworks.jpg')
  if not cached.exists():
   try:subprocess.run(['/bin/cp','-c',str(ROOT/item['relative_path']),str(cached)],check=True,timeout=8)
   except (subprocess.TimeoutExpired,subprocess.CalledProcessError):
    print(sid+': source read delayed; will retry on resume',flush=True);continue
  data=cached.read_bytes();assert sha(data)==item['sha256'],'Input hash mismatch'
  text=prompt;attempts=[];parsed=None;errors=[]
  for number in [1,2]:
   prior=rows(run/'attempts.jsonl');spent=sum(r.get('cost_usd_list_calculated') if r.get('cost_usd_list_calculated') is not None else reservation for r in prior)
   if spent+reservation>args.budget:stop=True;errors=['Budget reservation prevents next call'];break
   payload={'model':MODEL,'messages':[{'role':'system','content':helper.SYSTEM_PROMPT},{'role':'user','content':[{'type':'text','text':text},{'type':'image_url','image_url':{'url':'data:image/jpeg;base64,'+base64.b64encode(data).decode()}}]}],'max_tokens':4096,'prompt_truncate_len':8192,'temperature':0,'reasoning_effort':'low','response_format':{'type':'json_schema','json_schema':{'name':'PhotoClassification','schema':schema}}}
   req=urllib.request.Request('https://api.fireworks.ai/inference/v1/chat/completions',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+secret})
   start=now();tick=time.perf_counter();response={};request_id=None;error=None;http_status=None
   try:
    with urllib.request.urlopen(req,timeout=90) as reply:response=json.load(reply);request_id=reply.headers.get('x-request-id');http_status=reply.status
   except urllib.error.HTTPError as exc:
    http_status=exc.code;error='HTTP '+str(exc.code)+': '+exc.read().decode(errors='replace')[:700]
   except Exception as exc:error=type(exc).__name__
   wall=(time.perf_counter()-tick)*1000
   usage=response.get('usage',{});pt=usage.get('prompt_tokens');ct=usage.get('completion_tokens');cached=usage.get('prompt_tokens_details',{}).get('cached_tokens') or 0
   cost=((pt-cached)*input_rate+cached*cache_rate+ct*output_rate)/1e6 if pt is not None and ct is not None else None
   choice=(response.get('choices') or [{}])[0];raw=choice.get('message',{}).get('content') or ''
   attempt={'sample_id':sid,'attempt_number':number,'request_started_utc':start,'request_finished_utc':now(),'elapsed_wall_ms':wall,'model_reported':response.get('model'),'request_id':request_id or response.get('id'),'http_status':http_status,'stop_reason':choice.get('finish_reason'),'raw_response_text':raw,'raw_result_event':response,'usage':{'input_tokens':pt,'output_tokens':ct,'cache_read_input_tokens':cached if pt is not None else None,'reasoning_tokens':usage.get('completion_tokens_details',{}).get('reasoning_tokens')},'cost_usd_list_calculated':cost,'actual_billed_api_cost_usd':None,'error':error}
   append(run/'raw-responses.jsonl',attempt)
   try:
    candidate=json.loads(raw);errors=[e.message for e in validator.iter_errors(candidate)]
    if error:errors.append(error)
    if not errors:parsed=candidate
   except Exception as exc:errors=[error or str(exc)]
   attempt.update(schema_ok=parsed is not None,validation_errors=errors);append(run/'attempts.jsonl',attempt);attempts.append(attempt)
   if pt is not None and pt>=8192:stop=True;errors.append('Input token cap reached; exclude from full-prompt comparison')
   if error or pt is None or ct is None:stop=True;break
   if parsed is not None:break
   text=prompt+helper.REPAIR_SUFFIX.format(errors='; '.join(errors)[:800],previous=raw[:1500])
  costs=[a['cost_usd_list_calculated'] for a in attempts if a['cost_usd_list_calculated'] is not None]
  pred={'sample_id':sid,'input_sha256':item['sha256'],'status':'success' if parsed is not None else 'failed','parsed_classification':parsed,'validation_errors':errors,'attempt_count':len(attempts),'first_attempt_schema_ok':attempts[0]['schema_ok'] if attempts else False,'final_schema_ok':parsed is not None,'total_wall_ms_across_attempts':sum(a['elapsed_wall_ms'] for a in attempts),'total_cost_usd_list_calculated':sum(costs) if costs else None}
  append(run/'predictions.jsonl',pred);append(run/'metrics.jsonl',{'sample_id':sid,'status':pred['status'],'end_to_end_ms':pred['total_wall_ms_across_attempts'],'actual_billed_api_cost_usd':None,'calculated_cost_usd':pred['total_cost_usd_list_calculated'],'cost_basis':'Published token rates applied to API-reported usage; not an invoice','retries':max(0,len(attempts)-1)})
  if parsed is not None:append(run/'search-documents.jsonl',helper.build_search_document(sid,parsed))
  print(f'{sid}: {pred["status"]}, {pred["total_wall_ms_across_attempts"]/1000:.2f}s, ${sum(costs):.6f}',flush=True)
  config.update(end_utc=now(),processed=len(rows(run/'predictions.jsonl')));save(run/'config.json',config)
  if stop:break
 config.update(status='stopped' if stop else ('complete' if len(rows(run/'predictions.jsonl'))==len(sample['items']) else 'source_pending'),end_utc=now());save(run/'config.json',config)
 builder=(SOURCE/'build_outputs.py').read_text().replace('Haiku 5.5','Fireworks '+args.model).replace('list prices, computed by Claude Code CLI (costBasis: list). Not actual billed cost; subscription billing is not per token.','Fireworks published token rates applied to reported usage; not an invoice.').replace('Requests used the Claude Code CLI with a subscription login; the CLI sends its own system prompt, which is replaced here with a minimal one','Direct Fireworks REST, schema-constrained decoding, temperature 0 and 4096-token cap differ from Haiku CLI defaults')
 (run/'build_outputs.py').write_text(builder);shutil.copy2(Path(__file__),run/'benchmark_fireworks.py')
 subprocess.run([__import__('sys').executable,str(run/'build_outputs.py')],check=True)
 # Embed the verified previews so the review works from any folder.
 import base64 as b64
 page=(run/'review.html').read_text()
 for item in sample['items']:
  preview=Path.home()/'Library/Application Support/PhotoSignal/benchmark-cache'/(item['sample_id']+'-fireworks.jpg')
  page=page.replace('../../../images-768/'+Path(item['relative_path']).name,'data:image/jpeg;base64,'+b64.b64encode(preview.read_bytes()).decode())
 (run/'review.html').write_text(page)
 (run/'README.md').write_text('Same immutable 30-photo Haiku sample and classification prompt/schema. Fireworks '+args.model+' remote API. Key retrieved only from macOS Keychain. Raw responses and token usage retained locally. Costs calculated from published rates, actual billed charges unknown. Human evaluation remains blank. Resume with benchmark_fireworks.py --run-dir '+str(run)+'\n')
 print('OUTPUT '+str(run),flush=True)
if __name__=='__main__':main()
