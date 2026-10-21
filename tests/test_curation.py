import importlib.util
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('curate_photos',Path(__file__).resolve().parents[1]/'scripts/curate_photos.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
class CurationValidation(unittest.TestCase):
    def test_subset_and_reasons(self):
        self.assertEqual(len(c.validate_selection({'picks':[{'id':'a','reason':'Clear expression'}]}, {'a','b'}, 2)),1)
    def test_invalid_model_output(self):
        for picks in [[{'id':'outside','reason':'x'}],[{'id':'a','reason':'x'}]*2,[{'id':'a','reason':''}],[],[{'id':'a','reason':'x','code':'bad'}]]:
            with self.subTest(picks=picks),self.assertRaises(ValueError):c.validate_selection({'picks':picks},{'a'},1)
if __name__=='__main__':unittest.main()
