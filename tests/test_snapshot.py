import importlib.util,json,tempfile,unittest
from pathlib import Path
from unittest import mock
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import catalog,cloud_index
from PIL import Image
spec=importlib.util.spec_from_file_location('snapshot',Path(__file__).resolve().parents[1]/'scripts/build_october_viewer.py')
snapshot=importlib.util.module_from_spec(spec);spec.loader.exec_module(snapshot)
class SnapshotTests(unittest.TestCase):
    def test_hash_failure_keeps_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);folder=base/'october-viewer';folder.mkdir();(folder/'index.html').write_text('previous good snapshot')
            runfolder=base/'cloud-index/2026-09';runfolder.mkdir(parents=True)
            run=cloud_index.open_run(runfolder)
            preview=base/'preview.jpg';Image.new('RGB',(20,20),'green').save(preview)
            run.execute("INSERT INTO jobs(job_id,asset_id,sample_id,input_sha256,source_modified_at,path,status) VALUES('j','a','1','incorrect','v1',?,'success')",(str(preview),));run.commit();run.close()
            db=catalog.connect(base);catalog.upsert_asset(db,dict(asset_id='a',modified_at='v1',created_at='2026-09-10T12:00:00Z'))
            db.execute("INSERT INTO semantic_metadata VALUES('a','v1','model','hash','prompt','{}','','now')");db.commit();db.close()
            with mock.patch.object(snapshot,'BASE',base),self.assertRaisesRegex(ValueError,'hash mismatch'):
                snapshot.build('2026-09')
            self.assertEqual((folder/'index.html').read_text(),'previous good snapshot')
if __name__=='__main__':unittest.main()
