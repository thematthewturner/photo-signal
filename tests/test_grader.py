import importlib.util,json,pathlib,sqlite3,tempfile,unittest
ROOT=pathlib.Path(__file__).parents[1]
spec=importlib.util.spec_from_file_location('grader_builder',ROOT/'scripts/compare_photo_models.py');grader=importlib.util.module_from_spec(spec);spec.loader.exec_module(grader)
class GraderTests(unittest.TestCase):
 def setUp(self):
  self.db=sqlite3.connect(':memory:')
  self.db.executescript('CREATE TABLE images(sample_id TEXT,sha256 TEXT);CREATE TABLE predictions(run_id TEXT,sample_id TEXT,classification_json TEXT);')
  self.classification={'caption':'A beach','objects':[]}
  self.db.execute('INSERT INTO images VALUES(?,?)',('photo','imagehash'))
  self.db.execute('INSERT INTO predictions VALUES(?,?,?)',('run','photo',json.dumps(self.classification)))
 def tearDown(self):self.db.close()
 def review(self,**kwargs):return dict(run_id='run',sample_id='photo',reviewer='human',caption_accuracy=5,**kwargs)
 def test_hashes_reject_stale_scores(self):
  with self.assertRaisesRegex(ValueError,'Stale prediction'):grader.validate_review(self.db,self.review(prediction_sha256='wrong'))
  with self.assertRaisesRegex(ValueError,'Image hash'):grader.validate_review(self.db,self.review(image_sha256='wrong'))
  r=grader.validate_review(self.db,self.review(image_sha256='imagehash',prediction_sha256=grader.prediction_digest(self.classification)))
  self.assertEqual(r['integrity_status'],'verified')
 def test_grades_validate_and_separate_ai(self):
  r=grader.validate_review(self.db,self.review(review_kind='ai'));self.assertEqual(r['reviewer'],'ai:human')
  for bad in [0,6,True,'excellent']:
   r=self.review();r['caption_accuracy']=bad
   with self.assertRaises(ValueError):grader.validate_review(self.db,r)
  r=self.review();r['caption_accuracy']='4';self.assertEqual(grader.validate_review(self.db,r)['caption_accuracy'],4)
  with self.assertRaisesRegex(ValueError,'Unknown prediction'):grader.validate_review(self.db,dict(run_id='absent',sample_id='photo'))
 def test_template_embedding_prevents_script_breakout(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'template.html';p.write_text('<script>const DATA=__BAKEOFF_DATA__;</script>')
   text=grader.render_page(p,{'caption':'</script><script>alert(1)</script>'})
   self.assertEqual(text.count('</script>'),1)
   payload=text.split('const DATA=',1)[1].split(';</script>',1)[0]
   self.assertEqual(json.loads(payload)['caption'],'</script><script>alert(1)</script>')
if __name__=='__main__':unittest.main()
