"""Read-only audit of monthly model outputs, catalog persistence, and real SQL searches."""
import argparse, collections, datetime, hashlib, json, sqlite3, statistics, sys
from pathlib import Path
import jsonschema
import catalog

BASE = Path.home() / 'Library/Application Support/PhotoSignal'


def ro(path):
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    return db


def audit(month):
    folder = BASE / 'cloud-index' / month
    run = ro(folder / 'run.sqlite'); db = ro(BASE / 'catalog.sqlite')
    schema = json.loads((Path(__file__).resolve().parents[1] / 'contracts/photo-classification.schema.json').read_text())
    validator = jsonschema.Draft202012Validator(schema)
    config = json.loads((folder / 'config.json').read_text())
    jobs = run.execute('SELECT * FROM jobs WHERE active=1 ORDER BY sample_id').fetchall()
    counts = collections.Counter(); problems = []; types = collections.Counter(); settings = collections.Counter()
    need_resolution = 0; people_assets = 0; name_counts = collections.Counter(); captions_over_60_words = 0
    for job in jobs:
        aid = job['asset_id']; c = json.loads(job['classification_json'] or 'null')
        counts['active_jobs'] += 1
        if job['status'] != 'success': problems.append([job['sample_id'], 'job_not_successful']); continue
        counts['successful_jobs'] += 1
        errors = list(validator.iter_errors(c))
        if errors: problems.append([job['sample_id'], 'schema_validation', [e.message for e in errors]])
        else: counts['schema_valid'] += 1
        row = db.execute('SELECT * FROM semantic_metadata WHERE asset_id=?', (aid,)).fetchone()
        if row is None: problems.append([job['sample_id'], 'missing_catalog_row']); continue
        counts['catalog_rows'] += 1
        if json.loads(row['classification_json']) == c: counts['identical_classifications'] += 1
        else: problems.append([job['sample_id'], 'classification_differs'])
        if row['input_sha256'] == job['input_sha256'] == hashlib.sha256(Path(job['path']).read_bytes()).hexdigest(): counts['preview_hashes_verified'] += 1
        else: problems.append([job['sample_id'], 'preview_hash_mismatch'])
        if row['prompt_sha256'] == config['prompt_sha256'] and row['model'] == config['model']: counts['model_prompt_verified'] += 1
        else: problems.append([job['sample_id'], 'model_prompt_mismatch'])
        asset = db.execute('SELECT active,modified_at FROM assets WHERE asset_id=?', (aid,)).fetchone()
        if asset and asset['active'] and asset['modified_at'] == row['source_modified_at']: counts['fresh_asset_links'] += 1
        else: problems.append([job['sample_id'], 'missing_or_stale_asset'])
        fts = db.execute('SELECT f.text FROM assets a JOIN search_fts f ON f.rowid=a.rowid WHERE a.asset_id=?', (aid,)).fetchall()
        if len(fts) == 1 and row['search_text'] and row['search_text'] in fts[0][0]: counts['search_documents_complete'] += 1
        else: problems.append([job['sample_id'], 'missing_or_incomplete_fts'])
        if c['caption'].strip(): counts['nonempty_captions'] += 1
        types[c['image_type']] += 1; settings.update(set(c['scene']['settings']))
        need_resolution += int(c['needs_higher_resolution'])
        captions_over_60_words += int(len(c['caption'].split()) > 60)
        names = [r[0] for r in db.execute("SELECT DISTINCT name FROM people WHERE asset_id=? AND source='apple_photos'", (aid,))]
        people_assets += bool(names); name_counts.update(names)
    repeated = run.execute('SELECT job_id,count(*) FROM attempts GROUP BY job_id HAVING count(*)>1').fetchall()
    # Fixed October examples exercise the app's actual query function, not a separate search implementation.
    examples = [('Riley + red dress', {'people_all': ['Riley'], 'text': 'red dress'}),
                ('Jordan + birthday cake', {'people_all': ['Jordan'], 'text': 'birthday cake'}),
                ('Jordan + dog', {'people_all': ['Jordan'], 'text': 'dog'}),
                ('Riley AND Jordan', {'people_all': ['Riley', 'Jordan']}),
                ('Bird + pond', {'text': 'bird pond'})]
    queries = []
    for label, plan in examples:
        if month == '2026-10': plan = dict(plan, after='2026-10-01', before='2026-11-01')
        measurements = [catalog.search(db, plan) for _ in range(3)]
        result = measurements[-1]
        queries.append(dict(label=label, plan=plan, matches=result['total_matches'],
                            median_query_ms=statistics.median(r['query_ms'] for r in measurements),
                            results=[dict(asset_id=r['asset_id'], created_at=r['created_at'], people=r['people'],
                                          caption=json.loads(r['semantic_json'])['caption'] if r['semantic_json'] else None)
                                     for r in result['results']]))
    result = dict(month=month, audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  method='Read-only SQLite audit; search tests use catalog.search directly. No paid model calls.',
                  checks=dict(counts), problems=problems, repeated_job_attempts=len(repeated),
                  image_types=dict(types), top_settings=settings.most_common(12),
                  model_requests_higher_resolution=need_resolution, captions_over_prompt_word_limit=captions_over_60_words,
                  apple_named_photos=people_assets, apple_name_associations=dict(name_counts),
                  queries=queries,
                  limitations=['Matching SQL output is not proof that every caption or Apple identity is correct.',
                               'Search tests use structured filters and keyword FTS, not natural-language interpretation or vector similarity.',
                               'No full-month human-labeled retrieval precision/recall evaluation has been performed.',
                               'Dates in query examples are UTC bounds; the exported month itself used the Mac local calendar.'])
    spotchecks = folder / 'visual-spotchecks.json'
    if spotchecks.exists(): result['visual_spotchecks'] = json.loads(spotchecks.read_text())
    (folder / 'sql-audit.json').write_text(json.dumps(result, indent=2))
    lines = ['# October SQL output audit', '', f"Checked {len(jobs)} active photo jobs. {len(problems)} integrity problems.", '',
             '| Check | Verified |', '|---|---:|']
    lines += [f'| {key.replace("_", " ")} | {value} |' for key, value in counts.items()]
    lines += ['', f'Apple People labels exist for {people_assets} photos. Identity accuracy was not independently verified.', '',
              '## Actual search results', '', '| Structured query | Matches | Median SQL ms (3 runs) |', '|---|---:|---:|']
    lines += [f'| {q["label"]} | {q["matches"]} | {q["median_query_ms"]:.2f} |' for q in queries]
    lines += ['', '## Content profile', '', f'Model-predicted image types: {dict(types)}.',
              f'Model requests a higher-resolution review for {need_resolution} images.',
              f'{captions_over_60_words} captions exceed the prompt’s 60-word instruction (the schema enforces a separate character limit).',
              '', '## Limits', ''] + ['- '+s for s in result['limitations']]
    if 'visual_spotchecks' in result:
        visual = result['visual_spotchecks']
        lines += ['', '## Visual spot-checks', '', visual['method'], '']
        for review in visual['reviews']:
            lines += [f'- **{review["sample_id"]}: {review["outcome"]}.** {review["notes"]}']
    (folder / 'sql-audit.md').write_text('\n'.join(lines)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in {'queries', 'apple_name_associations'}}, indent=2))
    print(json.dumps([dict(label=q['label'], matches=q['matches'], median_query_ms=q['median_query_ms']) for q in queries], indent=2))
    run.close(); db.close()


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--month',default='2026-10');a=p.parse_args();audit(a.month)
