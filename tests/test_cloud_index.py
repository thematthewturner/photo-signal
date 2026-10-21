import importlib.util, json, pathlib, sqlite3, sys, tempfile, unittest
from unittest import mock
from types import SimpleNamespace
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
import cloud_index as cloud
import catalog


class CloudTests(unittest.TestCase):
    def test_recovered_preview_adds_only_one_new_paid_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=pathlib.Path(tmp);source=base/'sandbox-cache/2026-10';source.mkdir(parents=True)
            (source/'a.jpg').write_bytes(b'preview a')
            rows=[dict(asset_id='a',sample_id='00001',modified_at='v1',files={'768':'a.jpg'}),
                  dict(asset_id='b',sample_id='00002',modified_at='v1',files={})]
            def manifest():
                (source/'manifest.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
                (source/'summary.json').write_text(json.dumps({'eligible_photos':2}))
            manifest()
            c=dict(caption='A dog outdoors',search_phrases=['dog'],scene=dict(settings=['garden'],background_elements=[],lighting=[],weather_visible=[]),image_type='photo',activities=[],objects=[],animals=[],visible_text=[])
            response=dict(response={},classification=c,error=None,ambiguous=False,input=100,output=200,cache=0,reasoning=0,cost=.0003,seconds=.01)
            original_connect=catalog.connect
            with mock.patch.object(cloud,'BASE',base), mock.patch.object(cloud,'STOP',False), mock.patch.object(cloud.catalog,'connect',side_effect=lambda:original_connect(base/'catalog')), mock.patch.object(cloud,'refresh_people',return_value={'status':'complete'}), mock.patch.object(cloud.subprocess,'run',return_value=SimpleNamespace(stdout='test credential')), mock.patch.object(cloud,'request_image',return_value=response) as request:
                cloud.run('2026-10',2,2)
                self.assertEqual(request.call_count,1)
                rows[0]['favorite']=True;manifest()
                cloud.run('2026-10',2,2)
                self.assertEqual(request.call_count,1)
                check=original_connect(base/'catalog')
                self.assertEqual(check.execute("SELECT favorite FROM assets WHERE asset_id='a'").fetchone()[0],1);check.close()
                (source/'b.jpg').write_bytes(b'preview b');rows[1]['files']={'768':'b.jpg'};manifest()
                cloud.run('2026-10',2,2)
                self.assertEqual(request.call_count,2)
                self.assertEqual(request.call_args.args[0]['asset_id'],'b')
            progress=json.loads((base/'cloud-index/2026-10/progress.json').read_text())
            self.assertEqual(progress['counts'],{'success':2})
            self.assertEqual(progress['requests'],2)
            self.assertEqual(progress['phase'],'complete')
            db=cloud.open_run(base/'cloud-index/2026-10')
            self.assertEqual(db.execute('SELECT count(*) FROM jobs WHERE active=1').fetchone()[0],2)
            db.close()

    def test_queue_upgrade_preserves_completed_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=pathlib.Path(tmp)
            db=sqlite3.connect(folder/'run.sqlite')
            db.execute('CREATE TABLE jobs(job_id TEXT PRIMARY KEY,asset_id TEXT,sample_id TEXT,input_sha256 TEXT,source_modified_at TEXT,path TEXT,status TEXT,classification_json TEXT,error TEXT)')
            db.execute("INSERT INTO jobs VALUES('job','asset','00001','hash','v1','preview','success','{}',NULL)")
            db.commit();db.close()
            db=cloud.open_run(folder)
            row=db.execute('SELECT status,active FROM jobs').fetchone()
            self.assertEqual(tuple(row),('success',1));db.close()
    def test_pending_and_unknown_billing_keep_budget_reservations(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = cloud.open_run(pathlib.Path(tmp))
            db.execute("INSERT INTO attempts(job_id,status,reservation) VALUES('a','running',?)", (cloud.RESERVE,))
            db.execute("INSERT INTO attempts(job_id,status,reservation) VALUES('b','unknown',?)", (cloud.RESERVE,))
            db.execute("INSERT INTO attempts(job_id,status,reservation,cost,input_tokens,output_tokens) VALUES('c','success',?,.001,100,200)", (cloud.RESERVE,))
            t = cloud.totals(db)
            self.assertAlmostEqual(t['reserved_usd'], cloud.RESERVE * 2)
            self.assertEqual(t['usage_unknown_requests'], 1)
            self.assertEqual(t['input_tokens'], 100)
            self.assertEqual(t['calculated_usd'], .001)
            db.close()

    def test_semantic_text_people_and_stale_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = catalog.connect(pathlib.Path(tmp))
            catalog.upsert_asset(db, {'asset_id':'a','modified_at':'v1','created_at':'2026-10-01'})
            c = dict(caption='Person hiking by a lake',search_phrases=['forest trail'],
                     scene=dict(settings=['mountains'],background_elements=[],lighting=[],weather_visible=[]),
                     image_type='photo',activities=[],objects=[],animals=[],visible_text=[])
            job = dict(asset_id='a',source_modified_at='v1',input_sha256='hash')
            cloud.import_result(db, job, c, 'prompt')
            with db:
                db.execute("INSERT INTO people VALUES('a','Alex','apple_photos','now')")
                catalog.refresh_search_asset(db, 'a')
            self.assertEqual(catalog.search(db, {'people_all':['Alex'],'text':'hiking'})['total_matches'], 1)
            catalog.rebuild_fts(db)
            self.assertEqual(catalog.search(db, {'people_all':['Alex'],'text':'hiking'})['total_matches'], 1)
            self.assertEqual(json.loads(catalog.search(db, {'text':'lake'})['results'][0]['semantic_json'])['caption'], c['caption'])
            with db:
                db.execute("UPDATE assets SET modified_at='v2' WHERE asset_id='a'")
                catalog.refresh_search_asset(db,'a')
            self.assertEqual(catalog.search(db, {'text':'hiking'})['total_matches'], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM semantic_metadata').fetchone()[0], 1)
            db.close()

    def test_invalid_preview_never_calls_network(self):
        result = cloud.request_image({'path':'/no/such/preview','input_sha256':'x'}, '', {}, 'unused')
        self.assertIsNone(result['classification'])
        self.assertFalse(result['ambiguous'])
        self.assertIsNone(result['cost'])


if __name__ == '__main__': unittest.main()

class HistoryBatchTests(unittest.TestCase):
    def test_batches_resume_and_cross_month_identical_bytes_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=pathlib.Path(tmp)
            def prepare(month, rows):
                source=base/'sandbox-cache'/month;source.mkdir(parents=True)
                records=[]
                for aid,blob in rows:
                    (source/(aid+'.jpg')).write_bytes(blob)
                    records.append(dict(asset_id=aid,sample_id=aid,modified_at='v1',created_at=month+'-01',files={'768':aid+'.jpg'}))
                (source/'manifest.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records))
                (source/'summary.json').write_text('{}')
            prepare('2026-09',[('a',b'one'),('b',b'two')]);prepare('2026-08',[('copy',b'one')])
            c=dict(caption='Dog',search_phrases=[],scene=dict(settings=[],background_elements=[],lighting=[],weather_visible=[]),image_type='photo',activities=[],objects=[],animals=[],visible_text=[])
            response=dict(response={},classification=c,error=None,ambiguous=False,input=100,output=100,cache=0,reasoning=0,cost=.0001,seconds=.01)
            original_connect=catalog.connect
            with mock.patch.object(cloud,'BASE',base),mock.patch.object(cloud,'STOP',False),mock.patch.object(cloud.catalog,'connect',side_effect=lambda:original_connect(base/'catalog')),mock.patch.object(cloud,'refresh_people',return_value={'status':'complete'}),mock.patch.object(cloud.subprocess,'run',return_value=SimpleNamespace(stdout='test')),mock.patch.object(cloud,'request_image',return_value=response) as request:
                cloud.run('2026-09',2,1,max_new=1,global_budget=2)
                self.assertEqual(request.call_count,1)
                self.assertEqual(json.loads((base/'cloud-index/2026-09/progress.json').read_text())['phase'],'batch_complete')
                cloud.run('2026-09',2,1,max_new=1,global_budget=2)
                self.assertEqual(request.call_count,2)
                # A new JPEG rendition of the same unchanged asset must not be billed again.
                (base/'sandbox-cache/2026-09/a.jpg').write_bytes(b'new JPEG rendition')
                cloud.run('2026-09',2,1,max_new=1,global_budget=2)
                self.assertEqual(request.call_count,2)
                audit=cloud.open_run(base/'cloud-index/2026-09')
                latest=audit.execute("SELECT analysis_input_sha256,input_sha256 FROM jobs WHERE asset_id='a' AND active=1").fetchone()
                self.assertEqual(latest[0],cloud.digest(b'one'))
                self.assertNotEqual(latest[0],latest[1]);audit.close()
                cloud.run('2026-08',2,1,max_new=1,global_budget=2)
                self.assertEqual(request.call_count,2)
                self.assertEqual(json.loads((base/'cloud-index/2026-08/progress.json').read_text())['counts'],{'success':1})
                db=cloud.open_run(base/'cloud-index/2026-09')
                with db: db.execute("UPDATE jobs SET status='unknown',classification_json=NULL WHERE asset_id='b'")
                db.close()
                prepare('2026-07',[('unknown-copy',b'two')])
                cloud.run('2026-07',2,1,max_new=1,global_budget=2)
                self.assertEqual(request.call_count,2)
                self.assertEqual(json.loads((base/'cloud-index/2026-07/progress.json').read_text())['counts'],{'unknown':1})
                prepare('2026-06',[('new',b'new')])
                cloud.run('2026-06',2,1,max_new=1,global_budget=.0001)
                self.assertEqual(request.call_count,2)
                self.assertEqual(json.loads((base/'cloud-index/2026-06/progress.json').read_text())['phase'],'budget_paused')
