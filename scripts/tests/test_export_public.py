"""export-public.sh의 Windows 소스 포함 규칙 회귀. 저장소 루트에서 실행.

임시 Git 저장소의 main만 내보내며 실제 공개 폴더나 원격에는 닿지 않는다.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path.cwd()
BASE_FILES = {
    'project.yml': 'name: DoIt\n',
    '.gitignore': 'build/\n.doit-export-state.json\n',
    'README.md': '# DoIt\n',
    'LICENSE': 'MIT\n',
    'THIRD_PARTY_NOTICES.md': '# 고지\n',
    'docs/PRD.md': '# PRD\n',
    'docs/ARCHITECTURE.md': '# ARCH\n',
    'docs/DESIGN.md': '# DESIGN\n',
    'docs/RELEASING.md': '# RELEASING\n',
    'DoIt/App.swift': 'import SwiftUI\n',
    'DoItTests/AppTests.swift': 'import XCTest\n',
    'windows/.gitignore': 'bin/\nobj/\n.vs/\n*.user\n',
    'windows/README.md': '# DoIt for Windows\n',
    'windows/DoIt.Core/TodoStore.cs': 'namespace DoIt.Core;\n',
    'windows/DoIt.Windows/DoIt.Windows.csproj': '<Project Sdk="Microsoft.NET.Sdk" />\n',
    'internal-notes.txt': '공개 목록 밖 파일\n',
}


class ExportPublicTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='doit-export-test-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        self.target = Path(self.temp.name) / 'out'
        for name, text in BASE_FILES.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        script = self.repo / 'scripts/export-public.sh'
        script.parent.mkdir(parents=True)
        shutil.copyfile(SOURCE / 'scripts/export-public.sh', script)
        script.chmod(0o755)
        # 추적하지 않는 빌드 산출물: 내보내기 대상이 아니어야 한다.
        for name in ('windows/DoIt.Windows/bin/Debug/DoIt.exe',
                     'windows/DoIt.Windows/obj/project.assets.json',
                     'windows/.vs/state.json'):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('build output\n')
        self.git('init', '-q', '-b', 'main')
        self.git('add', '-A')
        self.commit()

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
        subprocess.run(['git', '-C', str(self.repo), *args], check=True, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def commit(self):
        self.git('-c', 'user.name=Test', '-c', 'user.email=test' + '@' + 'example.invalid',
                 'commit', '-q', '-m', 'fixture')

    def export(self):
        return subprocess.run([str(self.repo / 'scripts/export-public.sh'), str(self.target)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def exported(self):
        return {str(p.relative_to(self.target)) for p in self.target.rglob('*') if p.is_file()}

    def test_windows_sources_exported_without_build_output(self):
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = self.exported()
        self.assertIn('windows/DoIt.Core/TodoStore.cs', files)
        self.assertIn('windows/DoIt.Windows/DoIt.Windows.csproj', files)
        self.assertIn('windows/README.md', files)
        self.assertNotIn('internal-notes.txt', files)
        self.assertFalse(any(part in {'bin', 'obj', '.vs'}
                             for name in files for part in Path(name).parts))

    def test_tracked_windows_build_output_is_refused(self):
        self.git('add', '-f', 'windows/DoIt.Windows/bin/Debug/DoIt.exe')
        self.commit()
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('windows-build-output', result.stderr)
        self.assertFalse(self.target.exists())

    def test_windows_readme_internal_reference_is_refused(self):
        (self.repo / 'windows/README.md').write_text('docs/' + 'tasks/T-000.md 참고\n')
        self.git('add', 'windows/README.md')
        self.commit()
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('internal-document-reference', result.stderr)

    def test_windows_private_home_is_refused(self):
        (self.repo / 'windows/DoIt.Core/TodoStore.cs').write_text('// ' + '/Users/' + 'someone/x\n')
        self.git('add', '-A')
        self.commit()
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('private-home', result.stderr)


if __name__ == '__main__':
    unittest.main()
