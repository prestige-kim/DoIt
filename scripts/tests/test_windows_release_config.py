"""windows_release_config.py 회귀. 임시 폴더와 합성 manifest만 쓰며 site 원본은 바꾸지 않는다."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/windows_release_config.py'
SITE = ROOT / 'site'
NODE = shutil.which('node')
OWNER_URL = 'https://github.com/prestige-kim/DoIt/releases/download/windows-v1.0.0-1/'


def payload(arch):
    return f'fake {arch} installer\n'.encode() * 50


class WindowsReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='doit-winrel-'))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.site = self.tmp / 'site'
        self.site.mkdir()
        for name in ('config.js', 'windows-download.js'):
            shutil.copyfile(SITE / name, self.site / name)
        self.target = self.site / 'windows-download.js'
        self.original = self.target.read_bytes()
        self.files = {}
        assets = {}
        for arch in ('x64', 'arm64'):
            name = f'DoIt-Windows-1.0.0-1-{arch}-Setup.exe'
            path = self.tmp / 'downloads' / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(payload(arch))
            self.files[arch] = path
            assets[arch] = {'filename': name, 'bytes': path.stat().st_size,
                            'sha256': hashlib.sha256(payload(arch)).hexdigest(),
                            'appMachine': arch, 'setupMachine': 'x86', 'signed': False}
        self.manifest = {'version': '1.0.0', 'build': 1, 'sourceCommit': 'a' * 40,
                         'dotnetSdk': '10.0.100', 'nsis': 'v3.13', 'assets': assets}

    def write_manifest(self, manifest=None):
        path = self.tmp / 'manifest.json'
        path.write_text(json.dumps(manifest or self.manifest), encoding='utf-8')
        return path

    def run_tool(self, *extra, manifest=None, node=False):
        args = [sys.executable, str(TOOL), str(self.write_manifest(manifest)), '--target', str(self.target)]
        if node:
            args += ['--node', NODE]
        env = dict(os.environ)
        if not node:
            env['PATH'] = os.pathsep.join(p for p in env.get('PATH', '').split(os.pathsep)
                                          if not (Path(p) / 'node').exists())
        return subprocess.run(args + list(extra), capture_output=True, text=True, env=env)

    def assert_refused(self, result, text):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_original_site_stays_unpublished(self):
        self.assertIn('releasePublished: false', (SITE / 'windows-download.js').read_text(encoding='utf-8'))

    def test_preview_does_not_write(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('미리보기', result.stdout)
        self.assertIn('+ export const WINDOWS_RELEASE', result.stdout)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_write_sets_expected_values(self):
        result = self.run_tool('--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.target.read_text(encoding='utf-8')
        self.assertNotIn('releasePublished: false', text)
        self.assertIn("releasePublished: true, version: '1.0.0', build: 1", text)
        for arch in ('x64', 'arm64'):
            self.assertIn(f"{arch}: {{ url: '{OWNER_URL}DoIt-Windows-1.0.0-1-{arch}-Setup.exe', "
                          f"sha256: '{self.manifest['assets'][arch]['sha256']}' }}", text)
        # 나머지 줄은 그대로.
        self.assertEqual(len(text.splitlines()), len(self.original.decode().splitlines()))
        again = self.run_tool('--write')
        self.assertEqual(again.returncode, 0)
        self.assertIn('바꿀 것이 없어요', again.stdout)

    def test_uppercase_hash_is_normalized(self):
        self.manifest['assets']['x64']['sha256'] = self.manifest['assets']['x64']['sha256'].upper()
        self.assertEqual(self.run_tool('--write').returncode, 0)
        self.assertIn(self.manifest['assets']['x64']['sha256'].lower(), self.target.read_text(encoding='utf-8'))

    def test_only_x64(self):
        del self.manifest['assets']['arm64']
        self.assert_refused(self.run_tool('--write'), '--only')
        result = self.run_tool('--only', 'x64', '--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.target.read_text(encoding='utf-8')
        self.assertIn('x64: {', text)
        line = next(l for l in text.splitlines() if l.startswith('export const WINDOWS_RELEASE'))
        self.assertNotIn('arm64', line)

    def test_only_missing_arch_refused(self):
        del self.manifest['assets']['arm64']
        self.assert_refused(self.run_tool('--only', 'arm64', '--write'), 'arm64 자산이 없어요')

    def test_bad_hash_refused(self):
        for bad in ['0' * 63, 'g' * 64, '', None, 'a' * 65]:
            self.manifest['assets']['x64']['sha256'] = bad
            self.assert_refused(self.run_tool('--write'), 'sha256')

    def test_bad_version_and_build_refused(self):
        for version in ['1.0', '01.0.0', '1.0.0-beta', 'v1.0.0', '1.0.70000', 1]:
            self.assert_refused(self.run_tool('--write', manifest=dict(self.manifest, version=version)), '버전')
        for build in [0, 65536, '1', True, 1.0, None]:
            self.assert_refused(self.run_tool('--write', manifest=dict(self.manifest, build=build)), '빌드')

    def test_bad_filename_refused(self):
        for name in ['DoIt-Windows-1.0.0-2-x64-Setup.exe', 'DoIt-1.0.0-1-x64-Setup.exe',
                     'DoIt-Windows-1.0.0-1-arm64-Setup.exe', '../DoIt-Windows-1.0.0-1-x64-Setup.exe']:
            self.manifest['assets']['x64']['filename'] = name
            self.assert_refused(self.run_tool('--write'), '파일명')

    def test_bad_architecture_refused(self):
        self.manifest['assets']['x86'] = dict(self.manifest['assets']['x64'])
        self.assert_refused(self.run_tool('--write'), '알 수 없는 아키텍처')
        del self.manifest['assets']['x86']
        self.manifest['assets']['arm64']['appMachine'] = 'x64'
        self.assert_refused(self.run_tool('--write'), 'appMachine')

    def test_signed_true_or_false_allowed_but_not_other_types(self):
        self.manifest['assets']['x64']['signed'] = 'no'
        self.assert_refused(self.run_tool('--write'), 'signed')

    def test_verify_file_match_and_mismatch(self):
        ok = self.run_tool('--verify-file', str(self.files['x64']), str(self.files['arm64']))
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assert_refused(self.run_tool('--write', '--verify-file', str(self.files['x64'])), '빠졌어요')
        self.files['arm64'].write_bytes(payload('arm64')[:-1] + b'X')
        self.assert_refused(self.run_tool('--write', '--verify-file', str(self.files['x64']),
                                          str(self.files['arm64'])), 'SHA-256')
        self.files['arm64'].write_bytes(payload('arm64') + b'extra')
        self.assert_refused(self.run_tool('--write', '--verify-file', str(self.files['x64']),
                                          str(self.files['arm64'])), '크기')
        other = self.tmp / 'Other.exe'
        other.write_bytes(b'x')
        self.assert_refused(self.run_tool('--write', '--verify-file', str(other)), '자산 이름')

    def test_missing_release_line_refused(self):
        self.original = self.original.replace(b'export const WINDOWS_RELEASE = Object.freeze({',
                                              b'export const WINDOWS_RELEASE = Object.freeze(\n  {')
        self.target.write_bytes(self.original)
        self.assert_refused(self.run_tool('--write'), 'WINDOWS_RELEASE')

    def test_bad_manifest_json_refused(self):
        result = subprocess.run([sys.executable, str(TOOL), str(self.tmp / 'missing.json'),
                                 '--target', str(self.target), '--write'], capture_output=True, text=True)
        self.assert_refused(result, 'manifest')
        broken = self.tmp / 'broken.json'
        broken.write_text('{', encoding='utf-8')
        result = subprocess.run([sys.executable, str(TOOL), str(broken), '--target', str(self.target),
                                 '--write'], capture_output=True, text=True)
        self.assert_refused(result, 'manifest')

    def test_ambiguous_or_placeholder_site_config_refused(self):
        config = self.site / 'config.js'
        text = config.read_text(encoding='utf-8')
        config.write_text(text.replace("repository: 'DoIt',", "repository: 'DoIt',\n  repository: 'Other',"),
                          encoding='utf-8')
        self.assert_refused(self.run_tool('--write'), 'repository')
        config.write_text(text.replace("owner: 'prestige-kim',", "owner: 'your-owner',"), encoding='utf-8')
        self.assert_refused(self.run_tool('--write'), 'owner/repository')

    @unittest.skipUnless(NODE, 'node가 없어 JS 실행 검사를 건너뜀')
    def test_node_runs_verified_windows_download(self):
        result = self.run_tool('--write', node=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('결과 일치', result.stdout)
        del self.manifest['assets']['arm64']
        result = self.run_tool('--only', 'x64', node=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('결과 일치', result.stdout)

    @unittest.skipUnless(NODE, 'node가 없어 JS 실행 검사를 건너뜀')
    def test_node_rejects_when_js_returns_null(self):
        # JS 검증 규칙이 도구와 어긋나면(여기서는 x64만 받도록 바꿈) 쓰기 전에 거부한다.
        self.original = self.original.replace(b"const architectures = ['x64', 'arm64'];",
                                              b"const architectures = ['x64'];")
        self.target.write_bytes(self.original)
        self.assert_refused(self.run_tool('--write', node=True), 'verifiedWindowsDownload')

    def test_missing_node_option_refused(self):
        self.assert_refused(self.run_tool('--write', '--node', str(self.tmp / 'no-node')), '--node')


if __name__ == '__main__':
    unittest.main()
