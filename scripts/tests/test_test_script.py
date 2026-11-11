"""실제 앱·키체인에 닿지 않는 test.sh 전체 흐름 회귀. 저장소 루트에서 실행."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path.cwd()
MOCK_COMMAND = r'''#!/usr/bin/python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['DOIT_TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + '\n')
state = pathlib.Path(os.environ['DOIT_TEST_RUNNING_STATE'])
if name == 'security':
    if os.environ['DOIT_TEST_SIGNING_FAILURE'] == '1':
        sys.exit(1)
    print('1) fixture "DoIt Self Signing"')
elif name == 'pgrep':
    if state.read_text() != '1':
        sys.exit(1)
    print('123 DoIt' if '-l' in sys.argv or '-lx' in sys.argv else '123')
elif name == 'pkill':
    state.write_text('0')
elif name == 'open':
    result = int(os.environ['DOIT_TEST_OPEN_RESULT'])
    if result == 0:
        state.write_text('1')
    sys.exit(result)
elif name == 'xcodegen':
    sys.exit(int(os.environ['DOIT_TEST_GENERATE_RESULT']))
elif name == 'xcodebuild':
    print(os.environ['DOIT_TEST_BUILD_OUTPUT'], end='')
    sys.exit(int(os.environ['DOIT_TEST_BUILD_RESULT']))
elif name != 'sleep':
    sys.exit('unexpected mock command')
'''


class TestScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='doit-test-script-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'scripts/lib').mkdir(parents=True)
        shutil.copyfile(SOURCE/'scripts/test.sh', self.root/'scripts/test.sh')
        self.bin = self.root/'mock-bin'
        self.bin.mkdir()
        for name in ['security', 'pgrep', 'pkill', 'open', 'sleep', 'xcodegen', 'xcodebuild']:
            command = self.bin/name
            command.write_text(MOCK_COMMAND)
            command.chmod(0o755)
        self.app = self.root/'InstalledFixture.app'
        self.app.mkdir()
        # 실제 common.sh를 복제하되 절대 경로 두 곳만 임시 mock 대상으로 바꾼다.
        # production에는 검사 생략 옵션을 추가하지 않는다.
        common = (SOURCE/'scripts/lib/common.sh').read_text()
        self.assertEqual(common.count('/usr/bin/security'), 1)
        self.assertEqual(common.count('/Applications/DoIt.app'), 1)
        common = common.replace('/usr/bin/security', str(self.bin/'security'))
        common = common.replace('/Applications/DoIt.app', str(self.app))
        (self.root/'scripts/lib/common.sh').write_text(common)
        self.log = self.root/'commands.jsonl'
        self.state = self.root/'running'

    def run_script(self, *, running=True, installed=True, build_result=0,
                   output='TEST SUCCEEDED\n', generate_result=0, open_result=0,
                   signing_failure=False):
        self.state.write_text('1' if running else '0')
        if not installed:
            self.app.rmdir()
        env = dict(os.environ,
                   PATH=str(self.bin)+':/usr/bin:/bin',
                   DOIT_TEST_COMMAND_LOG=str(self.log),
                   DOIT_TEST_RUNNING_STATE=str(self.state),
                   DOIT_TEST_BUILD_RESULT=str(build_result),
                   DOIT_TEST_BUILD_OUTPUT=output,
                   DOIT_TEST_GENERATE_RESULT=str(generate_result),
                   DOIT_TEST_OPEN_RESULT=str(open_result),
                   DOIT_TEST_SIGNING_FAILURE=str(int(signing_failure)))
        result = subprocess.run(['/bin/zsh', 'scripts/test.sh', '-only-testing:DoItTests/Fixture'],
                                cwd=self.root, env=env, capture_output=True, text=True,
                                timeout=20)
        commands = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.names = [command[0] for command in commands]
        self.commands = commands
        return result

    def test_success_restores_originally_running_app_and_passes_arguments(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names.count('pkill'), 1)
        self.assertEqual(self.names.count('open'), 1)
        self.assertEqual(self.state.read_text(), '1')
        self.assertIn('TEST SUCCEEDED', result.stdout)
        build = next(command for command in self.commands if command[0] == 'xcodebuild')
        self.assertIn('-only-testing:DoItTests/Fixture', build)

    def test_failed_build_status_is_preserved_after_restore(self):
        result = self.run_script(build_result=65, output='TEST FAILED\n')
        self.assertEqual(result.returncode, 65)
        self.assertIn('TEST FAILED', result.stdout)
        self.assertEqual(self.names.count('open'), 1)

    def test_no_output_success_does_not_inherit_grep_failure(self):
        self.assertEqual(self.run_script(output='').returncode, 0)
        self.assertEqual(self.names.count('open'), 1)

    def test_no_output_failure_preserves_build_status(self):
        self.assertEqual(self.run_script(build_result=65, output='').returncode, 65)
        self.assertEqual(self.names.count('open'), 1)

    def test_generation_failure_restores_app_without_starting_build(self):
        result = self.run_script(generate_result=37)
        self.assertEqual(result.returncode, 37)
        self.assertNotIn('xcodebuild', self.names)
        self.assertEqual(self.names.count('open'), 1)

    def test_originally_stopped_app_is_not_opened(self):
        self.assertEqual(self.run_script(running=False).returncode, 0)
        self.assertNotIn('pkill', self.names)
        self.assertNotIn('open', self.names)
        self.assertEqual(self.state.read_text(), '0')

    def test_missing_installation_is_not_opened(self):
        self.assertEqual(self.run_script(installed=False).returncode, 0)
        self.assertNotIn('open', self.names)

    def test_failed_restore_is_reported_after_successful_build(self):
        result = self.run_script(open_result=9)
        self.assertEqual(result.returncode, 1)
        self.assertIn('직접 실행해 주세요', result.stderr)

    def test_failed_restore_does_not_hide_build_failure(self):
        result = self.run_script(build_result=65, open_result=9)
        self.assertEqual(result.returncode, 65)

    def test_signing_check_failure_does_not_touch_app(self):
        result = self.run_script(signing_failure=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('pgrep', self.names)
        self.assertNotIn('pkill', self.names)
        self.assertNotIn('open', self.names)
        self.assertNotIn('xcodebuild', self.names)


if __name__ == '__main__':
    unittest.main()
