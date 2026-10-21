#!/usr/bin/env python3
"""Local-only Ollama vision benchmark using the immutable Haiku pilot contract."""
import argparse, base64, hashlib, importlib.util, json, platform, shutil, statistics, subprocess, time, urllib.request
from datetime import datetime, timezone
from pathlib import Path
import jsonschema

ROOT = Path.home()/'Documents/PhotoSignal-Sandbox/2026-09'
CACHE = Path.home()/'Library/Application Support/PhotoSignal/benchmark-cache'
SOURCE = ROOT/'results/haiku-5.5/20261018T225131Z'
API = 'http://127.0.0.1:11434'
def now(): return datetime.now(timezone.utc).isoformat()
def sha(data): return hashlib.sha256(data).hexdigest()
def write(path, value): path.write_text(json.dumps(value, indent=2)+'\n')
def append(path, value):
    with path.open('a') as f: f.write(json.dumps(value)+'\n'); f.flush()
def rows(path): return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []
def request(endpoint, payload):
    req = urllib.request.Request(API+endpoint, data=json.dumps(payload).encode(), headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=600) as r: return json.load(r)
def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--model',default='qwen3.5:2b'); parser.add_argument('--run-dir',type=Path)
    args=parser.parse_args()
    run=args.run_dir or ROOT/'results'/args.model.replace(':','-')/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run.mkdir(parents=True,exist_ok=True)
    for name in ['sample.json','asset-map.json','prompt.txt','classification.schema.json']:
        if not (run/name).exists(): shutil.copy2(SOURCE/name,run/name)
    # Reuse only Haiku's deterministic search assembler and review builder, never its predictions.
    shutil.copy2(SOURCE/'run_benchmark.py',run/'haiku_contract_helpers.py')
    spec=importlib.util.spec_from_file_location('contract',run/'haiku_contract_helpers.py'); helpers=importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
    builder=(SOURCE/'build_outputs.py').read_text().replace('Haiku 5.5',args.model)
    builder=builder.replace('list prices, computed by Claude Code CLI (costBasis: list). Not actual billed cost; subscription billing is not per token.','Local Ollama inference; no provider API charges. Electricity and hardware costs not measured.')
    builder=builder.replace('Requests used the Claude Code CLI with a subscription login; the CLI sends its own system prompt, which is replaced here with a minimal one','Local Ollama with schema-constrained JSON; different runtime and decoding settings from Haiku, so timing is not purely a model comparison')
    (run/'build_outputs.py').write_text(builder)
    shutil.copy2(Path(__file__),run/'benchmark_local.py')
    sample=json.loads((run/'sample.json').read_text()); schema=json.loads((run/'classification.schema.json').read_text()); prompt=(run/'prompt.txt').read_text()
    validator=jsonschema.Draft202012Validator(schema)
    details=request('/api/show',{'model':args.model})
    if 'vision' not in details.get('capabilities',[]): raise RuntimeError('Model does not report vision capability')
    config_path=run/'config.json'
    config=json.loads(config_path.read_text()) if config_path.exists() else {
      'run_id':run.name,'start_utc':now(),'model_requested':args.model,'provider':'local Ollama','inference_location':'local','remote_images':False,
      'runtime':{'ollama':subprocess.check_output(['ollama','--version'],text=True).strip(),'python':platform.python_version(),'os':platform.platform()},
      'model_details':details,'hardware':{'chip':'Apple M2','physical_memory_bytes':int(subprocess.check_output(['sysctl','-n','hw.memsize']))},
      'model_settings':{'think':False,'temperature':0,'seed':42,'num_ctx':4096,'num_predict':2048,'format':'JSON Schema','keep_alive':'10m'},
      'concurrency':1,'prompt_sha256':sha(prompt.encode()),'schema_sha256':sha((run/'classification.schema.json').read_bytes()),
      'sample_source':str(SOURCE/'sample.json'),'image_preprocessing':'Unchanged JPEG bytes. Internal model image preprocessing may differ.',
      'comparison_differences':['Ollama schema-constrained decoding vs Haiku prompt-only JSON','temperature 0 and fixed seed; Haiku defaults','2048 output token cap; Haiku CLI default','think false vs Haiku low effort','First request includes cold model loading; load durations saved separately'],
      'actual_billed_api_cost_usd':0,'electricity_hardware_cost_usd':None,'status':'running'}
    write(config_path,config)
    done={p['sample_id'] for p in rows(run/'predictions.jsonl')}
    for item in sample['items']:
        sid=item['sample_id']
        if sid in done: continue
        image_path=CACHE/(sid+'.jpg')
        if not image_path.exists():
            append(run/'predictions.jsonl',{'sample_id':sid,'status':'failed','parsed_classification':None,'attempt_count':0,'first_attempt_schema_ok':False,'final_schema_ok':False,'validation_errors':['Local image cache unavailable; source filesystem read timed out']})
            print(sid+': source unavailable',flush=True); continue
        data=image_path.read_bytes()
        if sha(data)!=item['sha256']: raise RuntimeError('Input hash mismatch: '+sid)
        attempts=[]; parsed=None; errors=[]; text=prompt
        for number in [1,2]:
            start=now(); tick=time.perf_counter(); response={}; error=None
            try:
                response=request('/api/chat',{'model':args.model,'messages':[{'role':'system','content':helpers.SYSTEM_PROMPT},{'role':'user','content':text,'images':[base64.b64encode(data).decode()]}],'stream':False,'think':False,'format':schema,'keep_alive':'10m','options':{'temperature':0,'seed':42,'num_ctx':4096,'num_predict':2048}})
            except Exception as exc: error=str(exc)
            elapsed=(time.perf_counter()-tick)*1000
            raw=response.get('message',{}).get('content','')
            attempt={'sample_id':sid,'attempt_number':number,'request_started_utc':start,'request_finished_utc':now(),'elapsed_wall_ms':elapsed,'model_reported':response.get('model'),'stop_reason':response.get('done_reason'),'raw_response_text':raw,'raw_result_event':response,'usage':{'input_tokens':response.get('prompt_eval_count'),'output_tokens':response.get('eval_count'),'reasoning_tokens':None,'cache_read_input_tokens':None,'cache_creation_input_tokens':None},'cost_usd_list_calculated':None,'actual_billed_api_cost_usd':0,'load_duration_ns':response.get('load_duration'),'prompt_eval_duration_ns':response.get('prompt_eval_duration'),'eval_duration_ns':response.get('eval_duration'),'total_duration_ns':response.get('total_duration'),'error':error}
            append(run/'raw-responses.jsonl',attempt)
            try:
                candidate=json.loads(raw); errors=[e.message for e in validator.iter_errors(candidate)]
                if error: errors.append(error)
                if not errors: parsed=candidate
            except Exception as exc: errors=[str(exc)]
            attempt.update(schema_ok=parsed is not None,validation_errors=errors)
            append(run/'attempts.jsonl',attempt); attempts.append(attempt)
            if parsed is not None or error: break
            text=prompt+helpers.REPAIR_SUFFIX.format(errors='; '.join(errors)[:800],previous=raw[:1500])
        status='success' if parsed is not None else 'failed'
        usage={k:sum(a['usage'][k] for a in attempts if a['usage'].get(k) is not None) if any(a['usage'].get(k) is not None for a in attempts) else None for k in attempts[0]['usage']}
        pred={'sample_id':sid,'input_sha256':item['sha256'],'status':status,'parsed_classification':parsed,'validation_errors':errors,'attempt_count':len(attempts),'first_attempt_schema_ok':attempts[0]['schema_ok'],'final_schema_ok':parsed is not None,'total_wall_ms_across_attempts':sum(a['elapsed_wall_ms'] for a in attempts),'total_usage_across_attempts':usage}
        append(run/'predictions.jsonl',pred)
        append(run/'metrics.jsonl',{'sample_id':sid,'status':status,'end_to_end_ms':pred['total_wall_ms_across_attempts'],'usage_total':usage,'load_duration_ms':sum((a.get('load_duration_ns') or 0)/1e6 for a in attempts),'retries':len(attempts)-1,'actual_billed_api_cost_usd':0,'electricity_hardware_cost_usd':None})
        if parsed is not None: append(run/'search-documents.jsonl',helpers.build_search_document(sid,parsed))
        assert sha(image_path.read_bytes())==item['sha256']
        print(f'{sid}: {status}, {pred["total_wall_ms_across_attempts"]/1000:.1f}s ({len(rows(run/"predictions.jsonl"))}/30)',flush=True)
        config['end_utc']=now(); config['processed']=len(rows(run/'predictions.jsonl')); write(config_path,config)
    config['end_utc']=now(); config['status']='complete'; write(config_path,config)
    subprocess.run([__import__('sys').executable,str(run/'build_outputs.py')],check=True)
    summary=json.loads((run/'summary.json').read_text()); summary['actual_billed_api_cost_usd']=0; summary['electricity_hardware_cost_usd']=None; summary['hardware_memory']=config['hardware']; write(run/'summary.json',summary)
    (run/'README.md').write_text('Local Ollama pilot, same sample/prompt/schema as Haiku. Photos sent only to 127.0.0.1. Raw outputs, durations and counts are recorded. No cloud API fees; electricity/hardware costs unmeasured. Human evaluation is blank. First image includes model loading. Schema-constrained decoding, temperature, output cap and runtime differ from Haiku.\n\nResume with sandbox .venv/bin/python benchmark_local.py --model '+args.model+' --run-dir '+str(run)+'\n')
    print('COMPLETE '+str(run),flush=True)
if __name__=='__main__': main()
