"""저장소 루트에서 실행. 모든 출력 plist/fixture는 임시 폴더에만 생성."""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('config', 'scripts/lib/update_config.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
# 제품의 현재 gate·버전과 무관한 명시적 비공개 준비 fixture.
BASE = {
    'SUFeedURL': 'https://fixture.github.io/DoIt/appcast.xml',
    'SUPublicEDKey': base64.b64encode(b'f' * 32).decode(),
    'DoItDistributionEnabled': False,
    'DoItUpdateValidation': False,
    'SUVerifyUpdateBeforeExtraction': True,
    'SUAllowsAutomaticUpdates': False,
    'SUAutomaticallyUpdate': False,
    'SUEnableSystemProfiling': False,
}

class UpdateConfigTests(unittest.TestCase):
    def enabled(self):
        return dict(BASE, DoItDistributionEnabled=True)

    def test_configured_but_disabled_fixture(self):
        self.assertEqual(BASE['SUFeedURL'], 'https://fixture.github.io/DoIt/appcast.xml')
        self.assertIs(BASE['DoItDistributionEnabled'], False)
        self.assertTrue(c.configured(BASE))
        self.assertFalse(c.ready(BASE))
        self.assertFalse(c.check_package(BASE))

    def test_missing_false_and_non_bool_gate_block(self):
        for flag in [None, False, 'true', 'false', 1, 0, [], {}]:
            p = self.enabled()
            if flag is None: p.pop('DoItDistributionEnabled')
            else: p['DoItDistributionEnabled'] = flag
            self.assertFalse(c.ready(p), repr(flag))
            self.assertFalse(c.check_package(p), repr(flag))

    def test_explicit_true_allows_valid_fixture(self):
        self.assertTrue(c.ready(self.enabled()))
        self.assertTrue(c.check_package(self.enabled()))

    def test_bad_address_key_and_security_policies(self):
        for url in ['', '$(FEED)', 'https://updates.example.invalid/appcast.xml',
                    'http://prestige-kim.github.io/DoIt/appcast.xml',
                    'http://127.0.0.1:8765/appcast.xml', 'https://localhost/appcast.xml',
                    'https://example.org/appcast.xml?x=1', 'https://me:pw'+'@'+'example.org/appcast.xml']:
            self.assertFalse(c.check_package(dict(self.enabled(), SUFeedURL=url)))
        for key in ['', 'invalid', 'A'*44]:
            self.assertFalse(c.check_package(dict(self.enabled(), SUPublicEDKey=key)))
        for key, value in dict(SUVerifyUpdateBeforeExtraction=False, SUAllowsAutomaticUpdates=True,
                               SUAutomaticallyUpdate=True, SUEnableSystemProfiling=True,
                               NSAppTransportSecurity={'NSAllowsArbitraryLoads': True}).items():
            p = self.enabled(); p[key] = value
            self.assertFalse(c.check_package(p))

    def test_validation_separate_exact_loopback_and_not_packageable(self):
        p = dict(BASE, DoItUpdateValidation=True, SUFeedURL='http://127.0.0.1:8765/appcast.xml')
        self.assertTrue(c.ready(p)); self.assertFalse(c.check_package(p))
        for url in ['http://localhost:8765/appcast.xml', 'http://127.0.0.1:9999/appcast.xml',
                    'https://prestige-kim.github.io/DoIt/appcast.xml']:
            self.assertFalse(c.ready(dict(p, SUFeedURL=url)))
        for flag in [None, 'true', 1, 0]:
            self.assertFalse(c.ready(dict(p, DoItUpdateValidation=flag)))

    def test_prepare_diagnostics_and_environment_cannot_unlock(self):
        with tempfile.TemporaryDirectory(prefix='doit-config-', dir='/private/tmp') as tmp:
            source = Path(tmp)/'source.plist'
            source.write_bytes(plistlib.dumps(BASE))
            out = Path(tmp)/'Info.plist'
            for build in ['Debug', 'Release', 'UpdateValidation']:
                result = subprocess.run(['python3', 'scripts/lib/update_config.py', 'prepare',
                    str(source), str(out), build], capture_output=True, text=True,
                    env=dict(os.environ, DoItDistributionEnabled='true'))
                self.assertEqual(result.returncode, 0)
                p = plistlib.loads(out.read_bytes())
                self.assertIs(p['DoItDistributionEnabled'], False)
                self.assertEqual(c.ready(p), build == 'UpdateValidation')
                self.assertFalse(c.check_package(p))
                if build != 'UpdateValidation':
                    self.assertIn('distribution is not enabled', result.stdout)
                    self.assertNotIn('NSAppTransportSecurity', p)
                else:
                    self.assertEqual(p['NSAppTransportSecurity'], {'NSAllowsLocalNetworking': True})
                package = subprocess.run(['python3','scripts/lib/update_config.py','package',str(out)], capture_output=True)
                self.assertEqual(package.returncode, 1)

    def test_enabled_fixture_stays_enabled_in_production_configs(self):
        with tempfile.TemporaryDirectory(prefix='doit-config-', dir='/private/tmp') as tmp:
            source = Path(tmp)/'source.plist'
            source.write_bytes(plistlib.dumps(self.enabled()))
            out = Path(tmp)/'Info.plist'
            for build in ['Debug', 'Release', 'UpdateValidation']:
                result = subprocess.run(['python3', 'scripts/lib/update_config.py', 'prepare',
                    str(source), str(out), build], capture_output=True, text=True,
                    env=dict(os.environ, DoItDistributionEnabled='false'))
                self.assertEqual(result.returncode, 0)
                p = plistlib.loads(out.read_bytes())
                self.assertIs(p['DoItDistributionEnabled'], True)
                self.assertTrue(c.ready(p))
                self.assertEqual(c.check_package(p), build != 'UpdateValidation')
                self.assertNotIn('distribution is not enabled', result.stdout)
                package = subprocess.run(['python3', 'scripts/lib/update_config.py', 'package',
                    str(out)], capture_output=True)
                self.assertEqual(package.returncode, int(build == 'UpdateValidation'))

if __name__ == '__main__':
    unittest.main()
