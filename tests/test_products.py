import importlib.util
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('install_products',Path(__file__).resolve().parents[1]/'scripts/install-products.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
class ProductLifecycle(unittest.TestCase):
    def test_login_recovers_crash_but_respects_normal_quit(self):
        p=installer.launch_plist(Path('/Users/example/Applications/Photo Signal Indexer.app'))
        self.assertEqual(p['KeepAlive'],{'SuccessfulExit':False})
        self.assertGreaterEqual(p['ThrottleInterval'],60)
        self.assertEqual(len(p['ProgramArguments']),1)
        self.assertEqual(p['LimitLoadToSessionType'],'Aqua')
        self.assertNotIn('--history',p['ProgramArguments'])
        self.assertNotIn('--resume',p['ProgramArguments'])
if __name__=='__main__':unittest.main()
