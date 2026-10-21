import importlib.util,json,pathlib,tempfile,unittest
ROOT=pathlib.Path(__file__).parents[1]
def module(name,file):
 s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
catalog=module('profile_test_catalog','catalog.py');profile=module('profile_builder','profile_catalog.py')
class ProfileTests(unittest.TestCase):
 def test_coverage_counts_stale_and_zero_values(self):
  with tempfile.TemporaryDirectory() as tmp:
   b=pathlib.Path(tmp);db=catalog.connect(b)
   with db:
    for aid,modified in [('a','v1'),('b','v2'),('c','v1')]:catalog.upsert_asset(db,dict(asset_id=aid,created_at='2025-02-01T12:00:00Z',modified_at=modified,media_type=1,width=100,height=200,media_subtypes=8,favorite=False))
    for aid,status in [('a','complete'),('b','complete'),('c','no_local_preview')]:catalog.upsert_analysis(db,dict(asset_id=aid,metadata={'modified_at':'v1'},pipeline_version='test',status=status,face_count=0,labels=[{'label':'beach','confidence':.8},{'label':'beach','confidence':.9}],ocr_text='hello'))
   db.close();out=b/'profile.html';result=profile.build((b/'catalog.sqlite').resolve(),out,ROOT/'web/profile.html')
   self.assertEqual((result['assets'],result['analyzed'],result['unavailable'],result['stale']),(3,1,1,1))
   html=out.read_text();raw=html.split("'use strict';const DATA=",1)[1].split(';\nconst $=',1)[0];data=json.loads(raw);group=data['groups'][0]
   self.assertEqual(group['tags'][2]['beach'],1)
   self.assertEqual(group['faces']['0'],1)
   self.assertEqual(group['fields']['photos.favorite'],3)
   self.assertEqual(group['subtypes']['Live Photo'],3)
   self.assertNotIn(str(b),html)
 def test_empty_values_and_zero_are_distinct(self):
  self.assertTrue(profile.present(False));self.assertTrue(profile.present(0));self.assertFalse(profile.present([]));self.assertFalse(profile.present(''))
