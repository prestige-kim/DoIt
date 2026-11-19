"""windows_release_config.py 회귀. 임시 폴더와 합성 manifest만 쓰며 site 원본(JS·JSON)은 바꾸지 않는다."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/windows_release_config.py'
SITE = ROOT / 'site'
NODE = shutil.which('node')
OWNER_URL = 'https://github.com/prestige-kim/DoIt/releases/download/windows-v1.0.0-1/'
UNPUBLISHED_JSON = b'{\n  "schemaVersion": 1,\n  "releasePublished": false\n}\n'


def load_tool():
    spec = importlib.util.spec_from_file_location('windows_release_config', TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def payload(arch):
    return f'fake {arch} installer\n'.encode() * 50


class WindowsReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='doit-winrel-'))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.site = self.tmp / 'site'
        self.site.mkdir()
        for name in ('config.js', 'windows-download.js', 'windows-release.json'):
            shutil.copyfile(SITE / name, self.site / name)
        self.target = self.site / 'windows-download.js'
        self.json_target = self.site / 'windows-release.json'
        self.original = self.target.read_bytes()
        self.original_json = self.json_target.read_bytes()
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

    def tool_args(self, *extra, manifest=None, unpublish=False):
        head = ['--unpublish'] if unpublish else [str(self.write_manifest(manifest))]
        return head + ['--target', str(self.target), '--json-target', str(self.json_target)] + list(extra)

    def run_tool(self, *extra, manifest=None, node=False, unpublish=False):
        args = [sys.executable, str(TOOL)] + self.tool_args(manifest=manifest, unpublish=unpublish)
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
        self.assertEqual(self.json_target.read_bytes(), self.original_json)

    def release_json(self):
        return json.loads(self.json_target.read_text(encoding='utf-8'))

    def assert_files_agree(self):
        # WINDOWS_RELEASE 한 줄과 JSON이 같은 버전·빌드·URL·해시를 가리키는지 비교한다.
        line = next(l for l in self.target.read_text(encoding='utf-8').splitlines()
                    if l.startswith('export const WINDOWS_RELEASE'))
        data = self.release_json()
        self.assertIn(f"version: '{data['version']}', build: {data['build']}, ", line)
        expected = ', '.join(f"{arch}: {{ url: '{asset['url']}', sha256: '{asset['sha256']}' }}"
                             for arch, asset in data['assets'].items())
        self.assertIn(f'assets: {{ {expected} }}', line)
        self.assertEqual(line.count('url:'), len(data['assets']))

    def test_original_site_stays_unpublished(self):
        self.assertIn('releasePublished: false', (SITE / 'windows-download.js').read_text(encoding='utf-8'))
        self.assertEqual((SITE / 'windows-release.json').read_bytes(), UNPUBLISHED_JSON)

    def test_preview_does_not_write(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('미리보기', result.stdout)
        self.assertIn('+ export const WINDOWS_RELEASE', result.stdout)
        self.assertIn('[windows-release.json]', result.stdout)
        self.assertIn('+  "releasePublished": true,', result.stdout)
        self.assertIn('-  "releasePublished": false', result.stdout)
        self.assertIn('JSON 다시 읽기 검사: 통과', result.stdout)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.json_target.read_bytes(), self.original_json)

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
        raw = self.json_target.read_bytes()
        self.assertTrue(raw.endswith(b'}\n'))
        self.assertNotIn(b'\r', raw)
        data = self.release_json()
        self.assertEqual(list(data), ['schemaVersion', 'releasePublished', 'version', 'build', 'assets'])
        self.assertEqual(data['schemaVersion'], 1)
        self.assertIs(data['releasePublished'], True)
        self.assertEqual((data['version'], data['build']), ('1.0.0', 1))
        self.assertEqual(list(data['assets']), ['x64', 'arm64'])
        for arch in ('x64', 'arm64'):
            self.assertEqual(data['assets'][arch], {
                'url': f'{OWNER_URL}DoIt-Windows-1.0.0-1-{arch}-Setup.exe',
                'sha256': self.manifest['assets'][arch]['sha256']})
        self.assertEqual(raw.decode(), json.dumps(data, indent=2) + '\n')
        self.assert_files_agree()
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
        self.assertEqual(list(self.release_json()['assets']), ['x64'])
        self.assertNotIn('arm64', self.json_target.read_text(encoding='utf-8'))
        self.assert_files_agree()

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

    def test_unpublish_preview_then_write(self):
        self.assertEqual(self.run_tool('--write').returncode, 0)
        published, published_json = self.target.read_bytes(), self.json_target.read_bytes()
        preview = self.run_tool(unpublish=True)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn('되돌리기', preview.stdout)
        self.assertIn('미리보기', preview.stdout)
        self.assertEqual(self.target.read_bytes(), published)
        self.assertEqual(self.json_target.read_bytes(), published_json)
        result = self.run_tool('--write', unpublish=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.json_target.read_bytes(), UNPUBLISHED_JSON)
        again = self.run_tool('--write', unpublish=True)
        self.assertIn('바꿀 것이 없어요', again.stdout)

    def test_unpublish_rejects_mixed_options(self):
        self.assert_refused(self.run_tool('--write', '--only', 'x64', unpublish=True), '--unpublish')
        args = [sys.executable, str(TOOL), str(self.write_manifest()), '--unpublish', '--target',
                str(self.target), '--json-target', str(self.json_target), '--write']
        self.assert_refused(subprocess.run(args, capture_output=True, text=True), '--unpublish')
        args = [sys.executable, str(TOOL), '--target', str(self.target), '--json-target',
                str(self.json_target), '--write']
        self.assert_refused(subprocess.run(args, capture_output=True, text=True), 'manifest')

    def test_missing_json_target_refused(self):
        self.json_target.unlink()
        result = self.run_tool('--write')
        self.assertEqual(result.returncode, 1)
        self.assertIn('windows-release.json', result.stderr)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertFalse(self.json_target.exists())

    def test_reread_check_rejects_bad_json(self):
        tool = load_tool()
        good = tool.release_json(tool.release_document('prestige-kim', 'DoIt', '1.0.0', 1, {
            'x64': {'sha256': 'a' * 64}}))
        self.assertEqual(tool.check_release_json(good, 'prestige-kim', 'DoIt')['build'], 1)
        self.assertIsNone(tool.check_release_json(tool.release_json(tool.release_document(
            None, None, None, None, {})), None, None))
        data = json.loads(good)
        x64 = data['assets']['x64']
        bad = [good.replace('\n', '\r\n'), good.rstrip('\n'), '{\n',
               json.dumps(dict(data, schemaVersion=2)) + '\n',
               json.dumps(dict(data, schemaVersion=True)) + '\n',
               json.dumps(dict(data, extra=1)) + '\n',
               json.dumps({'schemaVersion': 1, 'releasePublished': False, 'version': '1.0.0'}) + '\n',
               json.dumps(dict(data, build=0)) + '\n',
               json.dumps(dict(data, version='1.0')) + '\n',
               json.dumps(dict(data, assets={})) + '\n',
               json.dumps(dict(data, assets={'x86': x64})) + '\n',
               json.dumps(dict(data, assets={'x64': dict(x64, sha256='A' * 64)})) + '\n',
               json.dumps(dict(data, assets={'x64': dict(x64, url='https://example.com/x.exe')})) + '\n',
               json.dumps(dict(data, assets={'x64': dict(x64, size=1)})) + '\n']
        for text in bad:
            with self.assertRaises(tool.Refused, msg=text):
                tool.check_release_json(text, 'prestige-kim', 'DoIt')

    def run_in_process(self, *extra):
        tool = load_tool()
        with mock.patch.object(tool, 'find_node', return_value=None), \
                mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            return tool.main(self.tool_args(*extra))

    def assert_site_untouched(self):
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.json_target.read_bytes(), self.original_json)
        self.assertEqual(sorted(p.name for p in self.site.iterdir()),
                         ['config.js', 'windows-download.js', 'windows-release.json'])

    def test_second_replace_failure_restores_both(self):
        real_replace = os.replace
        calls = []

        def failing_replace(src, dst):
            calls.append(dst)
            if len(calls) == 2:
                raise OSError('simulated')
            return real_replace(src, dst)

        with mock.patch('os.replace', side_effect=failing_replace):
            code = self.run_in_process('--write')
        self.assertEqual(code, 1)
        self.assertGreaterEqual(len(calls), 3)  # 첫 파일 교체, 두 번째 실패, 첫 파일 복원
        self.assert_site_untouched()

    def test_prepare_failure_writes_nothing(self):
        real_mkstemp = tempfile.mkstemp

        def failing_mkstemp(*args, **kwargs):
            if 'windows-release' in kwargs.get('prefix', ''):
                raise OSError('simulated')
            return real_mkstemp(*args, **kwargs)

        with mock.patch('tempfile.mkstemp', side_effect=failing_mkstemp):
            code = self.run_in_process('--write')
        self.assertEqual(code, 1)
        self.assert_site_untouched()

    @unittest.skipUnless(NODE, 'node가 없어 JS 실행 검사를 건너뜀')
    def test_node_runs_verified_windows_download(self):
        result = self.run_tool('--write', node=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('결과 일치', result.stdout)
        del self.manifest['assets']['arm64']
        result = self.run_tool('--only', 'x64', node=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('결과 일치', result.stdout)
        result = self.run_tool('--write', unpublish=True, node=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('결과 일치', result.stdout)
        self.assertEqual(self.json_target.read_bytes(), UNPUBLISHED_JSON)

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
