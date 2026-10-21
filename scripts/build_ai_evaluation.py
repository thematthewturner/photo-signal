"""Export blinded visual assessments and a reproducible, completion-aware summary."""
import json
import statistics
from pathlib import Path

BASE = Path.home() / 'Library/Application Support/PhotoSignal/benchmark-comparison'


def weighted(review):
    values = [review.get(k) for k in ('caption_accuracy', 'detail_coverage', 'search_usefulness')]
    return sum(v * w for v, w in zip(values, (.5, .3, .2))) if all(isinstance(v, (int, float)) for v in values) else None


def build():
    work = json.loads((BASE / 'ai-judge-worklist.json').read_text())
    assessments = json.loads((BASE / 'ai-visual-assessments.json').read_text())
    data = json.loads((BASE / 'comparison-data.json').read_text())
    reviews = []
    for photo in work:
        assessment = assessments[photo['sample_id']]
        assert set(assessment['grades']) == {a['label'] for a in photo['answers']}
        for answer in photo['answers']:
            accuracy, coverage, search, unsupported, rationale = assessment['grades'][answer['label']]
            reviews.append(dict(
                run_id=answer['run_id'], sample_id=photo['sample_id'],
                reviewer='ai:Codex assistant visual review', reviewer_type='ai', review_kind='ai',
                image_sha256=photo['image_sha256'], prediction_sha256=answer['prediction_sha256'],
                caption_accuracy=accuracy, detail_coverage=coverage, search_usefulness=search,
                setting_accuracy=None, activity_accuracy=None, object_accuracy=None,
                hallucination_count=unsupported if accuracy is not None else None,
                unsupported_claims=rationale if unsupported else None,
                overall_acceptable='yes' if accuracy is not None and accuracy >= 4 and search >= 4 else 'no',
                notes=rationale, visible_evidence=assessment['evidence'],
                identity_revealed_at_review='blind', blind_label=answer['label'],
                judge_metadata={'method': 'Single assistant visual review of actual exported previews, shuffled labels per photo',
                                'exact_judge_model': 'unmeasured',
                                'dimensions_scored': ['accuracy of caption and inspected semantic fields', 'relevant detail coverage', 'search usefulness'],
                                'not_tested': ['named-person recognition', 'retrieval precision or recall', 'full-resolution originals', 'independent human ground truth']}
            ))
    rubric = {
        'scale': '1 poor, 3 usable with corrections, 5 accurate and useful',
        'composite': '0.5 accuracy + 0.3 relevant detail coverage + 0.2 search usefulness, out of 5',
        'acceptable': 'accuracy >= 4 and search usefulness >= 4',
        'unsupported_claim_count': 'Flagged claims only; includes overconfident details not established by preview, not an exhaustive hallucination rate',
        'quality_denominator': 'Successful predictions with all three scores; failed outputs excluded from fidelity means',
        'completion_adjustment': 'Missing or failed outputs contribute zero to mean over all 30 sample images',
        'paired_comparison': 'Seven complete-attempt cloud runs compared on their common successful images; local four-image run excluded',
        'limitations': 'One AI judge, subjective coarse scores, small month sample with related photos, low-resolution previews, differing runtime wrappers. Differences are provisional; no significance claim.'
    }
    exported = {'schema_version': '2.0', 'rubric': rubric, 'reviews': reviews}
    (BASE / 'ai-visual-grades.json').write_text(json.dumps(exported, indent=2))
    groups = {r['run_id']: [v for v in reviews if v['run_id'] == r['run_id']] for r in data['runs']}
    full = [r for r, gg in groups.items() if len(gg) == len(work)]
    paired = set.intersection(*[{g['sample_id'] for g in groups[r] if weighted(g) is not None} for r in full])
    summary = []
    for run in data['runs']:
        gg = groups[run['run_id']]
        valid = [g for g in gg if weighted(g) is not None]
        rr = [r for r in data['records'] if r['run_id'] == run['run_id']]
        times = [r['elapsed_ms']/1000 for r in rr if r.get('elapsed_ms') is not None]
        costs = [r['calculated_usd'] for r in rr if r.get('calculated_usd') is not None]
        pg = [g for g in valid if g['sample_id'] in paired]
        mean = lambda vals: statistics.mean(vals) if vals else None
        summary.append(dict(run_id=run['run_id'], model=run['model'], successful=len(valid), sample_size=len(work),
                            accuracy=mean([g['caption_accuracy'] for g in valid]),
                            coverage=mean([g['detail_coverage'] for g in valid]),
                            search=mean([g['search_usefulness'] for g in valid]),
                            composite=mean([weighted(g) for g in valid]),
                            completion_adjusted=sum(weighted(g) for g in valid)/len(work),
                            paired_composite=mean([weighted(g) for g in pg]) if run['run_id'] in full else None,
                            paired_n=len(pg) if run['run_id'] in full else 0,
                            acceptable=sum(g['overall_acceptable']=='yes' for g in valid),
                            outputs_with_flagged_claims=sum(g['hallucination_count']>0 for g in valid),
                            flagged_claims=sum(g['hallucination_count'] for g in valid),
                            median_seconds=statistics.median(times) if times else None,
                            timing_n=len(times), calculated_cost_usd=sum(costs) if costs else None, cost_n=len(costs)))
    summary.sort(key=lambda r: (r['paired_composite'] is not None, r['paired_composite'] or 0), reverse=True)
    result = {'rubric': rubric, 'paired_sample_ids': sorted(paired), 'models': summary}
    (BASE / 'ai-judge-summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    build()
