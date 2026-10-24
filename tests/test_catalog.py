import importlib.util, pathlib, tempfile, json, unittest
spec=importlib.util.spec_from_file_location('catalog',pathlib.Path(__file__).parents[1]/'scripts/catalog.py')
catalog=importlib.util.module_from_spec(spec);spec.loader.exec_module(catalog)

class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.base=pathlib.Path(self.tmp.name);self.db=catalog.connect(self.base)
        rows=[dict(asset_id='a',created_at='2026-10-14T12:00:00Z',modified_at='v1',media_type=1,width=100,height=100,favorite=True),
              dict(asset_id='b',created_at='2026-10-15T12:00:00Z',modified_at='v1',media_type=1,width=100,height=100)]
        (self.base/'inventory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        (self.base/'people-tags.json').write_text(json.dumps({'a':{'people':['Riley','Jordan'],'confirmed_at':'now'},'b':{'people':['Riley']}}))
        catalog.sync(self.db,self.base)
    def tearDown(self): self.db.close();self.tmp.cleanup()
    def test_explicit_natural_language_filters_do_not_need_llm(self):
        self.assertCountEqual(catalog.plan_local(self.db,'photos of Riley and Jordan')['people_all'],['Riley','Jordan'])
        plan=catalog.plan_local(self.db,'favorite photos from 2025')
        self.assertEqual(plan['favorite'],True)
        self.assertEqual(plan['before'],'2026-01-01')
        self.assertEqual(catalog.plan_local(self.db,'photos with at least four faces')['min_faces'],4)
    def test_vector_bytes_are_persisted_separately(self):
        import base64
        row=dict(asset_id='a',pipeline_version='test',feature_print_base64=base64.b64encode(b'archived-feature').decode(),feature_revision=2)
        with self.db:catalog.upsert_analysis(self.db,row)
        self.assertEqual(bytes(self.db.execute('SELECT data FROM vectors').fetchone()[0]),b'archived-feature')
        self.assertNotIn('feature_print_base64',json.loads(self.db.execute('SELECT raw_json FROM analysis').fetchone()[0]))
    def test_people_intersection_and_unknown(self):
        self.assertEqual(catalog.search(self.db,{'people_all':['riley','Jordan']})['total_matches'],1)
        self.assertEqual(catalog.search(self.db,{'people_all':['Alex']})['total_matches'],0)
    def test_injection_is_data_and_plan_is_bounded(self):
        self.assertEqual(catalog.search(self.db,{'people_all':["' OR 1=1 --"]})['total_matches'],0)
        for plan in [{'sql':'DELETE FROM assets'},{'limit':10001},{'after':'not-a-date'},{'favorite':'true'}]:
            with self.assertRaises((ValueError,TypeError)):catalog.validate(plan)
        self.assertEqual(self.db.execute('SELECT count(*) FROM assets').fetchone()[0],2)
    def test_incremental_analysis_and_stale_results(self):
        p=self.base/'analysis.jsonl'
        r={'asset_id':'a','metadata':{'modified_at':'v1'},'pipeline_version':'test','face_count':2,'labels':[{'label':'beach','confidence':.9}],'ocr_text':'summer vacation'}
        p.write_text('\n'+json.dumps(r)+'\n');catalog.sync(self.db,self.base)
        self.assertEqual(catalog.search(self.db,{'text':'beach','min_faces':2})['total_matches'],1)
        with p.open('a') as f:f.write(json.dumps(dict(r,asset_id='b',ocr_text='mountain'))+'\n')
        catalog.sync(self.db,self.base)
        self.assertEqual(catalog.search(self.db,{'text':'mountain'})['results'][0]['asset_id'],'b')
        with self.db:self.db.execute("UPDATE assets SET modified_at='v2' WHERE asset_id='a'")
        self.assertEqual(catalog.search(self.db,{'min_faces':2})['total_matches'],1)
    def test_tags_remove_and_inventory_deletions(self):
        (self.base/'people-tags.json').write_text('{}');catalog.sync(self.db,self.base)
        self.assertEqual(catalog.search(self.db,{'people_all':['Riley']})['total_matches'],0)
        (self.base/'inventory.jsonl').write_text(json.dumps({'asset_id':'a','media_type':1})+'\n');catalog.sync(self.db,self.base)
        self.assertEqual(catalog.search(self.db,{})['total_matches'],1)
    def test_partial_log_line_is_retried(self):
        p=self.base/'analysis.jsonl';p.write_text('{"asset_id":')
        catalog.sync(self.db,self.base)
        with p.open('a') as f:f.write('"a","ocr_text":"receipt","metadata":{"modified_at":"v1"}}\n')
        catalog.sync(self.db,self.base)
        self.assertEqual(catalog.search(self.db,{'text':'receipt'})['total_matches'],1)

if __name__=='__main__':unittest.main()
