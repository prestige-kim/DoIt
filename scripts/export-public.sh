#!/bin/sh
# main의 공개 파일만 로컬 폴더로 내보낸다. Git 이력·네트워크 작업 없음.
set -eu
if [ "$#" -ne 1 ]; then
    echo '사용법: scripts/export-public.sh <빈 대상폴더 또는 이전 내보내기 폴더>' >&2
    exit 1
fi
if [ ! -x /usr/bin/python3 ]; then
    echo 'Xcode Command Line Tools의 /usr/bin/python3가 필요해요.' >&2
    exit 1
fi
exec /usr/bin/python3 - "$0" "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile

STATE = '.doit-export-state.json'
REQUIRED = {'project.yml', '.gitignore', 'README.md', 'LICENSE',
            'THIRD_PARTY_NOTICES.md', 'docs/PRD.md', 'docs/ARCHITECTURE.md',
            'docs/DESIGN.md', 'docs/RELEASING.md', 'scripts/export-public.sh'}
ROOTS = {'DoIt', 'DoItTests', 'scripts', 'site', '.github'}
FIXTURE = 'DoItTests/Fixtures/fake-feed.ics'
FORBIDDEN_PARTS = {'.git', 'build', 'dist', 'DerivedData', 'xcuserdata',
                   'archive', 'node_modules', '.ssh', '.aws', '.codex', '.agents'}
PRIVATE_NAMES = {'todos.json', 'lms.json', 'lms-state.json', 'lms-history.json',
                 'lms-feed-url', 'AGENTS.md', 'CLAUDE.md', '.env', '.DS_Store',
                 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519'}
KEY_SUFFIXES = {'.p12', '.pfx', '.cer', '.crt', '.pem', '.key',
                '.certsigningrequest', '.mobileprovision', '.keystore'}

class Refused(Exception):
    pass

def file_label(path):
    if not path:
        return '(대상/상태)'
    encoded = path.encode('utf-8', errors='replace')
    if any(p.search(encoded) for p in RULES.values()) or FEED.search(encoded):
        return '(개인정보 가능성이 있는 파일명 숨김)'
    return json.dumps(path, ensure_ascii=True)

def refuse(rule, path=None, count=1):
    # 경로나 입력값을 예외 본문으로 전달하지 않는다. 파일명은 JSON 이스케이프.
    name = file_label(path)
    raise Refused('차단: 규칙={} 파일={} 건수={}'.format(rule, name, count))

def git(*args):
    p = subprocess.run(['git', '-C', str(source), *args], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=dict(os.environ, GIT_NO_REPLACE_OBJECTS='1'))
    if p.returncode:
        refuse('git-read')
    return p.stdout

def allowed(name):
    return name in REQUIRED or name.split('/')[0] in ROOTS

def path_check(name, public_only=True):
    p = PurePosixPath(name)
    if (not name or p.is_absolute() or str(p) != name or
            any(x in {'', '.', '..'} for x in name.split('/')) or
            any(ord(c) < 32 or ord(c) == 127 for c in name)):
        refuse('unsafe-path')
    if (any(x in FORBIDDEN_PARTS or x.endswith('.xcodeproj') for x in p.parts) or
            any(name == prefix or name.startswith(prefix + '/')
                for prefix in ('docs/tasks', 'docs/reports', 'docs/handoff'))):
        refuse('private-path', name)
    if (p.name in PRIVATE_NAMES or p.name.startswith('.env.') or
            p.suffix.lower() in KEY_SUFFIXES or
            re.search(r'(?:sparkle.*private|private.*sparkle|eddsa.*private|\.p8$)', name, re.I)):
        refuse('secret-file', name)
    if p.suffix.lower() == '.ics' and name != FIXTURE:
        refuse('non-fixture-calendar', name)
    if public_only and not allowed(name):
        refuse('outside-public-list', name)

# 내용에 포함된 실제 값을 출력하지 않는다. 정규식은 소스 자체가 비밀 예제가 되지 않도록 작성.
RULES = {
    'private-key-header': re.compile(rb'-{5}BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-{5}'),
    'service-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})\b'),
    'private-home': re.compile(rb'(?:/Users/|/home/)[A-Za-z0-9_.-]+'),
    'email': re.compile(rb'(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'sparkle-private-key': re.compile(rb'(?:SUPrivateEDKey|SPARKLE_PRIVATE_KEY|(?:private|secret)[_ -]?(?:ed25519|eddsa)[_ -]?key)\s*[=:]\s*[\x22\x27]?[A-Za-z0-9+/=]{20,}', re.I),
    'assigned-secret': re.compile(rb'(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[=:]\s*[\x22\x27][A-Za-z0-9_+/=-]{20,}[\x22\x27]', re.I),
}
URL = re.compile(rb'(?:https?|webcal)://[^\s\x22\x27<>`\\)]+', re.I)
FEED = re.compile(rb'/feeds/calendars/([A-Za-z0-9_%?&=.+-]+)', re.I)
INTERNAL = re.compile(rb'(?:docs/(?:tasks|reports|handoff)/|(?:\.\./)?plans/|AGENTS\.md|CLAUDE\.md)')

def scan(name, data):
    failures = []
    for rule, pattern in RULES.items():
        hits = list(pattern.finditer(data))
        if rule == 'email':
            icon_json = 'DoIt/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json'
            menu_json = 'DoIt/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json'
            exceptions = set()
            if name == icon_json or name in {
                    str(PurePosixPath(icon_json).parent / ('icon_{0}x{0}'.format(size) + '@' + '2x.png'))
                    for size in (16, 32, 128, 256, 512)}:
                exceptions = {('icon_{0}x{0}'.format(size) + '@' + '2x.png').encode()
                              for size in (16, 32, 128, 256, 512)}
            if name in {menu_json, 'scripts/make-icons.swift',
                        str(PurePosixPath(menu_json).parent / ('menubar' + '@' + '2x.png'))}:
                exceptions = {('menubar' + '@' + '2x.png').encode()}
            if name == 'DoItTests/LmsPolicyTests.swift':
                exceptions = {('pw' + '@' + 'lms.example.invalid').encode()}
            if name == 'THIRD_PARTY_NOTICES.md':
                # Sparkle 2.10.1 LICENSE의 Ed25519 원 저작권 고지에 필요한 이메일 1개.
                exceptions = {('orsonpeters' + '@' + 'gmail.com').encode()}
            hits = [m for m in hits if m.group() not in exceptions]
        if hits:
            failures.append((rule, len(hits)))
    # 가짜 주소 예외: 테스트 Swift 파일 안의 정확한 example.invalid 호스트만.
    # URL 검증기의 경로 문자열(식별자 없는 접두사)은 FEED에 매칭되지 않는다.
    feed_data = data
    if name.startswith('DoItTests/') and name.endswith('.swift'):
        feed_data = URL.sub(lambda m: b'' if re.match(
            rb'(?:https?|webcal)://lms\.example\.invalid(?=[:/]|$)', m.group(), re.I) else m.group(), data)
    if name == 'DoItTests/LmsPolicyTests.swift':
        prefix = b'/feeds/' + b'calendars/'
        # 기존 거부 테스트의 가짜 자격 정보·호스트 없음·다른 가짜 호스트.
        for literal in (b'https://me:pw' + b'@' + b'lms.example.invalid' + prefix + b'user_FAKE.ics',
                        b'https://' + prefix + b'user_FAKE.ics',
                        b'https://other.example.invalid' + prefix + b'user_A.ics'):
            feed_data = feed_data.replace(literal, b'')
    n = len(FEED.findall(feed_data))
    if n:
        failures.append(('personal-feed', n))
    if name in {'README.md', 'docs/PRD.md', 'docs/ARCHITECTURE.md', 'docs/DESIGN.md', 'docs/RELEASING.md'}:
        n = len(INTERNAL.findall(data))
        if n:
            failures.append(('internal-document-reference', n))
    return failures

def no_links(path):
    # /tmp가 링크인 macOS에서는 /private/tmp 사용. ..로 링크 검사를 우회하지 못함.
    raw = Path(os.path.abspath(path))
    for parent in [raw, *raw.parents]:
        if parent.is_symlink():
            refuse('target-symlink')
    return raw.resolve()

def safe_target_path(name):
    p = target / name
    for part in [p, *p.parents]:
        if part == target.parent:
            break
        if part.is_symlink():
            refuse('target-symlink', name)
    return p

def digest(data):
    return hashlib.sha256(data).hexdigest()

def snapshot(path):
    return {'sha256': digest(path.read_bytes()), 'mode': stat.S_IMODE(path.stat().st_mode)}

def preserved_files(managed):
    # .git은 이름만 확인해 제외한다. stat·열기·순회 모두 금지.
    # 모든 보존 경로·파일 종류를 먼저 검사한 뒤 일반 파일만 내용 검사한다.
    files = []
    if not target.exists():
        return files
    def walk(directory):
        with os.scandir(directory) as children:
            for child in sorted(children, key=lambda e: e.name):
                if directory == target and child.name in {'.git', STATE}:
                    continue
                name = str(Path(child.path).relative_to(target))
                path_check(name, public_only=False)
                info = child.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    refuse('target-symlink', name)
                if stat.S_ISDIR(info.st_mode):
                    walk(Path(child.path))
                elif not stat.S_ISREG(info.st_mode):
                    refuse('target-special-file', name)
                elif name not in managed:
                    files.append((name, info))
    walk(target)
    return files

def preserved_data(name, expected):
    # 경로 검사 뒤 링크·특수 파일로 교체된 경우에도 따라가거나 대기하지 않는다.
    fd = os.open(target / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        actual = os.fstat(f.fileno())
        if (not stat.S_ISREG(actual.st_mode) or
                (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino)):
            refuse('target-file-changed', name)
        return f.read()

def run():
    global source, target
    script = Path(sys.argv[1]).resolve()
    source = script.parent.parent
    source = Path(git('rev-parse', '--show-toplevel').decode().strip()).resolve()
    # 원래 인자 경로의 링크도 검사 (abspath가 ..를 먼저 제거하는 경우 포함).
    raw = Path(os.path.expanduser(sys.argv[2]))
    for parent in [raw, *raw.parents]:
        if parent.is_symlink():
            refuse('target-symlink')
    target = no_links(str(raw))
    home = Path.home().resolve()
    if (target == Path('/') or target == home or target == source or
            target in source.parents or source in target.parents):
        refuse('dangerous-target')
    if target.exists() and not target.is_dir():
        refuse('target-not-directory')
    sha = git('rev-parse', '--verify', 'refs/heads/main^{commit}').decode().strip()
    entries = {}
    excluded = 0
    for item in git('ls-tree', '-rz', '--full-tree', sha).split(b'\0'):
        if not item:
            continue
        meta, name_bytes = item.split(b'\t', 1)
        mode, kind, oid = meta.decode().split()
        try:
            name = name_bytes.decode('utf-8')
        except UnicodeDecodeError:
            refuse('non-utf8-path')
        # .ics와 링크는 목록 밖에서도 본문을 읽기 전에 거부.
        if PurePosixPath(name).suffix.lower() == '.ics' and name != FIXTURE:
            refuse('non-fixture-calendar', name)
        if mode not in {'100644', '100755'} or kind != 'blob':
            refuse('symlink-or-submodule', name)
        if not allowed(name):
            excluded += 1
            continue
        path_check(name)
        entries[name] = (oid, 0o755 if mode == '100755' else 0o644)
    missing = REQUIRED - entries.keys()
    if missing or not all(any(n.startswith(root + '/') for n in entries) for root in ('DoIt', 'DoItTests', 'scripts')):
        print('main에 필수 파일이 없어요. 작업 브랜치가 아직 main에 병합되기 전일 수 있어요.', file=sys.stderr)
        refuse('missing-main-file', sorted(missing)[0] if missing else None, len(missing) or 1)
    state_path = safe_target_path(STATE)
    previous = {}
    if state_path.exists():
        if not state_path.is_file() or state_path.stat().st_size > 4_000_000:
            refuse('invalid-state')
        try:
            state = json.loads(state_path.read_text())
            if (set(state) != {'version', 'main_sha', 'files'} or state['version'] != 1 or
                    not re.fullmatch('[0-9a-f]{40,64}', state['main_sha']) or not isinstance(state['files'], dict)):
                refuse('invalid-state')
            previous = state['files']
            for name, info in previous.items():
                path_check(name)
                if (not isinstance(info, dict) or set(info) != {'sha256', 'mode'} or
                        not re.fullmatch('[0-9a-f]{64}', info['sha256']) or info['mode'] not in (0o644, 0o755)):
                    refuse('invalid-state')
        except (ValueError, TypeError, KeyError):
            refuse('invalid-state')
    elif target.exists() and any(p.name != '.git' for p in target.iterdir()):
        refuse('first-target-not-empty')
    # 전체 preflight: 관리 밖 파일 덮어쓰기·수정된 관리 파일 삭제도 거부.
    for name in sorted(set(entries) | set(previous)):
        p = safe_target_path(name)
        for parent in p.parents:
            if parent == target:
                break
            if parent.exists() and not parent.is_dir():
                refuse('target-parent-not-directory', name)
        if p.exists():
            if not p.is_file():
                refuse('target-not-regular-file', name)
            if name not in previous:
                refuse('unmanaged-file-conflict', name)
            if snapshot(p) != previous[name]:
                refuse('managed-file-modified', name)
    preserved = preserved_files(set(entries) | set(previous))
    # 별도 staging에는 고정한 커밋의 blob만 쓴다.
    with tempfile.TemporaryDirectory(prefix='doit-export-') as temp:
        stage = Path(temp) / 'stage'
        stage.mkdir()
        findings = []
        manifest = {}
        for name, (oid, mode) in sorted(entries.items()):
            data = git('cat-file', 'blob', oid)
            for rule, count in scan(name, name.encode()) + scan(name, data):
                findings.append((rule, name, count))
            p = stage / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            p.chmod(mode)
            manifest[name] = snapshot(p)
        for name, info in preserved:
            data = preserved_data(name, info)
            for rule, count in scan(name, name.encode()) + scan(name, data):
                findings.append((rule, name, count))
        if findings:
            for rule, name, count in findings:
                print('차단: 규칙={} 파일={} 건수={}'.format(rule, file_label(name), count), file=sys.stderr)
            raise Refused('안전 검사 실패. 대상은 변경하지 않았어요.')
        if STATE.encode() not in (stage / '.gitignore').read_bytes().splitlines():
            refuse('state-not-gitignored', '.gitignore')
        new_state = {'version': 1, 'main_sha': sha, 'files': manifest}
        (stage / STATE).write_text(json.dumps(new_state, ensure_ascii=True, indent=2, sort_keys=True) + '\n')
        (stage / STATE).chmod(0o600)
        # 실패 시 기존 관리 파일 복구. 관리 밖 파일에는 쓰지 않고 .git은 열지 않는다.
        changed = sorted(set(entries) | set(previous)) + [STATE]
        backup = Path(temp) / 'backup'
        backup.mkdir()
        existed = set()
        created_dirs = []
        target_existed = target.exists()
        # 백업 실패는 반영 시작 전 종료하므로 대상 파일에 영향이 없다.
        for name in changed:
            p = safe_target_path(name)
            if p.exists():
                b = backup / name
                b.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, b)
                existed.add(name)
        try:
            for name in changed:
                p = safe_target_path(name)
                pending = []
                parent = p.parent
                while not parent.exists():
                    pending.append(parent)
                    parent = parent.parent
                for directory in reversed(pending):
                    directory.mkdir()
                    created_dirs.append(directory)
                staged = stage / name
                if staged.exists():
                    # 같은 디렉터리의 임시 파일을 rename: 파일별 교체는 원자적.
                    fd, tmp = tempfile.mkstemp(prefix='.doit-export-', dir=str(p.parent))
                    try:
                        with os.fdopen(fd, 'wb') as f:
                            f.write(staged.read_bytes())
                        os.chmod(tmp, stat.S_IMODE(staged.stat().st_mode))
                        os.replace(tmp, p)
                    finally:
                        if os.path.lexists(tmp):
                            os.unlink(tmp)
                elif p.exists():
                    p.unlink()
        except OSError:
            for name in changed:
                p = safe_target_path(name)
                if name in existed:
                    shutil.copy2(backup / name, p)
                elif p.is_file():
                    p.unlink()
            for directory in reversed(created_dirs):
                directory.rmdir()
            if not target_existed and target.exists():
                target.rmdir()
            refuse('apply-failed-rolled-back')
    print('완료: main={} 내보낸 main 파일={} 원본 제외={}'.format(sha, len(entries), excluded))
    print('경로·내용 검사: main 파일={} 보존한 관리 밖 일반 파일={} 발견=0'.format(len(entries), len(preserved)))
    print('검사 제외: 대상 최상위 .git(비접근), 로컬 관리 상태 파일(별도 형식 검사).')
    print('삭제한 이전 관리 파일={}. 대상 .git과 관리 밖 파일은 보존했어요.'.format(len(set(previous) - set(entries))))
    print('관리 목록: .doit-export-state.json (커밋 제외). 자동 검사는 비밀 부재의 보증이 아니에요.')

try:
    run()
except Refused as e:
    print(str(e), file=sys.stderr)
    print('위험 파일은 자동 삭제하지 않아요. 표시된 문제를 확인하고 공개 대상에서 직접 정리한 뒤 다시 실행하세요.', file=sys.stderr)
    sys.exit(1)
except (OSError, UnicodeError, ValueError, TypeError):
    # 예외 메시지에는 비밀·대상 절대경로가 있을 수 있으므로 출력하지 않는다.
    print('차단: 규칙=io-or-format-error 파일=(대상/상태) 건수=1', file=sys.stderr)
    sys.exit(1)
PY
