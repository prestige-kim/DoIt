#!/usr/bin/python3
"""로컬 릴리스 준비. 표준 라이브러리만 사용하며 업로드·게시·Git 변경 명령은 없다."""
import argparse
import base64
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

# import도 캐시를 쓰지 않도록 wrapper가 -B로 실행한다.
from update_config import check_package

ROOT = Path(__file__).resolve().parents[2]
ACCOUNT = 'com.personal.doit.updates'
SPARKLE_VERSION = '2.10.1'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
TAG = '{' + NS + '}'
SEMVER = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
MAX_BUILD = 2**31 - 1
MAX_NOTES = 32768
SCHEMA = {'schema', 'source_commit', 'source_version', 'version', 'build', 'zip', 'size',
          'sha256', 'ed25519_signature', 'public_key', 'download_url', 'minimum_os',
          'notes_file', 'notes_sha256', 'appcast_file', 'appcast_sha256',
          'project_before_sha256', 'project_after_sha256', 'sparkle_version'}
SENSITIVE = {
    'private-path': re.compile(r'(?:/Users/|/home/)[\w.-]+|~/', re.I),
    'email': re.compile(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', re.I),
    'personal-feed': re.compile(r'/feeds/(?:calendars|calendar)/', re.I),
    'private-key': re.compile(r'-{5}BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-{5}'),
    'service-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})\b'),
    'assigned-secret': re.compile(r'(?:private[_ -]?key|secret|password|access[_-]?token)\s*[=:]\s*[\x22\x27]?[A-Za-z0-9_+/=-]{20,}', re.I),
    'bare-key': re.compile(r'(?m)^[A-Za-z0-9+/]{43,}={0,2}$'),
}

class Rejected(Exception):
    def __init__(self, rule, count=1):
        self.rule, self.count = rule, count
        super().__init__(rule)

def reject(rule, count=1):
    raise Rejected(rule, count)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def run(args, rule, cwd=None):
    # SDK·서명 도구의 임의 출력에 경로/비밀이 섞여도 호출자에게 내보내지 않는다.
    process = subprocess.Popen([str(x) for x in args], cwd=cwd or ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1'))
    try:
        stdout, _ = process.communicate()
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        except ProcessLookupError:
            pass
        raise
    if process.returncode:
        reject(rule)
    return stdout

def git(*args):
    return run(['git', '-C', ROOT, *args], 'git-read').decode().strip()

def safe_path(path):
    path = Path(path).absolute()
    for p in (path, *path.parents):
        if p.is_symlink():
            reject('symlink-input')
    return path

def read_file(path, limit):
    path = safe_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        s = os.fstat(f.fileno())
        if not stat.S_ISREG(s.st_mode) or s.st_size > limit:
            reject('input-type-or-size')
        data = f.read(limit + 1)
    if len(data) > limit:
        reject('input-too-large')
    return data

def sensitive(text):
    for rule, pattern in SENSITIVE.items():
        count = len(pattern.findall(text))
        if count:
            reject(rule, count)

def notes_text(path):
    p = safe_path(path)
    # 금지 파일의 본문은 열지 않는다. 명시한 md/txt 일반 파일 1개만 허용한다.
    lower = p.name.lower()
    if (p.suffix.lower() not in {'.md', '.txt'} or
            any(part in {'.git', '.ssh', '.aws', 'Library'} for part in p.parts) or
            any(word in lower for word in ('private', 'secret', 'signing-key', 'lms-feed', 'keychain'))):
        reject('notes-forbidden-path')
    data = read_file(p, MAX_NOTES)
    try:
        text = data.decode('utf-8')
    except UnicodeError:
        reject('notes-encoding')
    if not text.strip() or not re.search(r'[가-힣ᄀ-ᇿ]', text):
        reject('notes-empty-or-not-korean')
    if any(ord(c) < 32 and c not in '\r\n\t' for c in text):
        reject('notes-control-character')
    sensitive(text)
    return text.replace('\r\n', '\n').replace('\r', '\n')

def version(value):
    m = re.fullmatch(SEMVER, value)
    if not m or any(len(p) > 9 for p in m.groups()):
        reject('invalid-version')
    return tuple(int(p) for p in m.groups())

def build_number(value):
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]{0,9}', value):
        reject('invalid-build-record')
    result = int(value)
    if result > MAX_BUILD:
        reject('build-overflow')
    return result

def scalar(text, name):
    matches = list(re.finditer(r'^\s*' + re.escape(name) + r':\s*([^\n]+)$', text, re.M))
    if len(matches) != 1:
        reject('project-scalar')
    raw = matches[0][1].strip()
    if raw.startswith(('"', "'")):
        if raw[-1] != raw[0] or len(raw) < 2:
            reject('project-scalar')
        return raw[1:-1]
    if raw in ('true', 'false'):
        return raw == 'true'
    return raw

def project_settings(data):
    text = data.decode('utf-8')
    current = scalar(text, 'MARKETING_VERSION')
    build = build_number(scalar(text, 'CURRENT_PROJECT_VERSION'))
    version(current)
    if scalar(text, 'exactVersion') != SPARKLE_VERSION:
        reject('sparkle-pin')
    keys = ('SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SUEnableSystemProfiling',
            'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUVerifyUpdateBeforeExtraction',
            'DoItUpdateValidation', 'DoItDistributionEnabled')
    info = {key: scalar(text, key) for key in keys}
    for key in keys[2:]:
        if type(info[key]) is not bool:
            reject('project-policy-type')
    # xcodegen이 추적 Info.plist를 뜻밖에 고치지 않도록 동기화 상태를 먼저 요구한다.
    template = plistlib.loads(read_file(ROOT / 'DoIt/Resources/Info.plist', 100000))
    if any(template.get(key) != value for key, value in info.items()) or 'NSAppTransportSecurity' in template:
        reject('project-plist-out-of-sync')
    return current, build, info

def repository(feed):
    if not isinstance(feed, str):
        reject('feed-policy')
    m = re.fullmatch(r'https://([a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?)\.github\.io/([A-Za-z0-9][A-Za-z0-9._-]{0,99})/appcast\.xml', feed)
    if not m or m[2] in {'.', '..'}:
        reject('feed-policy')
    return m[1], m[2]

def download_url(info, marketing, build):
    owner, repo = repository(info['SUFeedURL'])
    return f'https://github.com/{owner}/{repo}/releases/download/v{marketing}-{build}/DoIt-{marketing}-{build}.zip'

def read_xml(data):
    if re.search(br'<!\s*(?:DOCTYPE|ENTITY)', data, re.I):
        reject('xml-doctype-or-entity')
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        root = ET.fromstring(data, parser=parser)
    except ET.ParseError:
        reject('invalid-appcast')
    if root.tag != 'rss' or root.get('version') != '2.0' or len(root.findall('channel')) != 1:
        reject('invalid-appcast')
    return root

def item_value(item, name):
    values = item.findall(TAG + name)
    enc = item.find('enclosure')
    legacy = enc.get(TAG + name) if enc is not None else None
    if len(values) > 1:
        reject('ambiguous-appcast-item')
    text = values[0].text if values else legacy
    if legacy is not None and values and legacy != text:
        reject('ambiguous-appcast-item')
    if not text:
        reject('incomplete-appcast-item')
    return text

def feed_builds(root):
    builds = []
    for item in root.find('channel').findall('item'):
        builds.append(build_number(item_value(item, 'version')))
        version(item_value(item, 'shortVersionString'))
    if len(builds) != len(set(builds)):
        reject('duplicate-appcast-build')
    return builds

def artifact_name(name):
    if not isinstance(name, str) or Path(name).name != name or not name or name.startswith('.'):
        reject('artifact-path')
    return name

def manifest_data(path):
    data = read_file(path, 100000)
    try:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    reject('duplicate-json-key')
                result[key] = value
            return result
        m = json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        reject('invalid-manifest')
    if not isinstance(m, dict) or set(m) != SCHEMA or m['schema'] != 1:
        reject('invalid-manifest-schema')
    if type(m['build']) is not int or build_number(str(m['build'])) != m['build']:
        reject('invalid-manifest-build')
    version(m['version'])
    if not isinstance(m['source_version'], dict) or set(m['source_version']) != {'version', 'build'}:
        reject('invalid-source-version')
    version(m['source_version']['version'])
    if type(m['source_version']['build']) is not int or build_number(str(m['source_version']['build'])) >= m['build']:
        reject('invalid-source-version')
    if not re.fullmatch(r'[0-9a-f]{40,64}', m['source_commit']):
        reject('invalid-source-sha')
    for field in ('sha256', 'notes_sha256', 'appcast_sha256', 'project_before_sha256', 'project_after_sha256'):
        if not re.fullmatch(r'[0-9a-f]{64}', m[field]):
            reject('invalid-manifest-hash')
    for field in ('zip', 'notes_file', 'appcast_file'):
        artifact_name(m[field])
    if type(m['size']) is not int or m['size'] <= 0 or m['minimum_os'] != '14.0.0' or m['sparkle_version'] != SPARKLE_VERSION:
        reject('invalid-manifest-metadata')
    sensitive(m['download_url'])
    if len(base64.b64decode(m['ed25519_signature'], validate=True)) != 64:
        reject('invalid-signature-format')
    return m

def records():
    dist = ROOT / 'dist'
    if not dist.exists():
        return []
    safe_path(dist)
    builds = []
    # 이 도구의 고유 릴리스 폴더만 이력으로 인정. 다른 파일은 읽거나 지우지 않는다.
    for p in sorted(dist.iterdir()):
        if p.is_symlink():
            reject('dist-symlink')
        match = re.fullmatch(r'DoIt-(' + SEMVER + r')-([1-9][0-9]*)', p.name)
        if p.is_dir() and match:
            m = manifest_data(p / 'release.manifest.json')
            if p.name != f"DoIt-{m['version']}-{m['build']}":
                reject('record-name-mismatch')
            for key, hkey in (('zip', 'sha256'), ('notes_file', 'notes_sha256'), ('appcast_file', 'appcast_sha256')):
                content = read_file(p / m[key], 512*1024*1024)
                if sha(content) != m[hkey]:
                    reject('record-hash-mismatch')
            if (p / m['zip']).stat().st_size != m['size']:
                reject('record-size-mismatch')
            record_metadata(p, m)
            builds.append(m['build'])
        elif p.name.startswith('DoIt-') and p.suffix == '.zip':
            # 이전 package 산출물은 이름에서 번호를 추측하지 않고 zip 내부 plist를 읽는다.
            match = re.fullmatch(r'DoIt-(' + SEMVER + r')-([1-9][0-9]*)\.zip', p.name)
            if not match:
                reject('invalid-legacy-archive-name')
            with zipfile.ZipFile(p) as archive:
                verify_zip_paths(archive)
                info = plistlib.loads(archive.read('DoIt.app/Contents/Info.plist'))
            if p.name != f"DoIt-{info.get('CFBundleShortVersionString')}-{info.get('CFBundleVersion')}.zip":
                reject('legacy-archive-metadata')
            builds.append(build_number(info['CFBundleVersion']))
        elif p.name.startswith('DoIt-'):
            reject('invalid-release-record')
    if len(builds) != len(set(builds)):
        reject('duplicate-release-build')
    return builds

def patched_project(before, marketing, build):
    text = before.decode('utf-8')
    text = re.sub(r'^(\s*MARKETING_VERSION:) [^\n]+$', lambda m: m[1]+' "'+marketing+'"', text, flags=re.M)
    return re.sub(r'^(\s*CURRENT_PROJECT_VERSION:) [^\n]+$', lambda m: m[1]+' "'+str(build)+'"', text, flags=re.M).encode()

def verify_provenance(m):
    data = run(['git','-C',ROOT,'show',m['source_commit']+':project.yml'], 'manifest-source-commit')
    if (sha(data) != m['project_before_sha256'] or
            scalar(data.decode('utf-8'),'MARKETING_VERSION') != m['source_version']['version'] or
            scalar(data.decode('utf-8'),'CURRENT_PROJECT_VERSION') != str(m['source_version']['build']) or
            sha(patched_project(data,m['version'],m['build'])) != m['project_after_sha256']):
        reject('manifest-source-version-diff')

def record_metadata(folder, m):
    verify_provenance(m)
    root = read_xml(read_file(folder/m['appcast_file'], 2_000_000))
    feed_builds(root)
    items = [i for i in root.find('channel').findall('item') if item_value(i,'version') == str(m['build'])]
    if len(items) != 1:
        reject('record-appcast-build')
    item = items[0]
    enclosure = item.find('enclosure')
    if (enclosure is None or enclosure.get('url') != m['download_url'] or
            enclosure.get('length') != str(m['size']) or enclosure.get(TAG+'edSignature') != m['ed25519_signature'] or
            item_value(item,'shortVersionString') != m['version'] or item.findtext(TAG+'minimumSystemVersion') != m['minimum_os'] or
            item.findtext('description') != notes_text(folder/m['notes_file'])):
        reject('record-appcast-mismatch')
    with zipfile.ZipFile(folder/m['zip']) as archive:
        verify_zip_paths(archive)
        info = plistlib.loads(archive.read('DoIt.app/Contents/Info.plist'))
    if (info.get('CFBundleVersion') != str(m['build']) or info.get('CFBundleShortVersionString') != m['version'] or
            info.get('SUPublicEDKey') != m['public_key'] or not check_package(info) or
            m['download_url'] != download_url(info,m['version'],m['build'])):
        reject('record-zip-metadata')

def tools_root(explicit):
    path = Path(explicit) if explicit else ROOT/'build/SourcePackages/artifacts/sparkle/Sparkle'
    path = safe_path(path)
    # framework의 정식 내부 symlink는 따라 읽되 도구 루트·실행 파일은 링크로 받지 않는다.
    for name in ('sign_update', 'generate_keys'):
        exe = path / 'bin' / name
        if exe.is_symlink() or not exe.is_file() or not os.access(exe, os.X_OK):
            reject('missing-sparkle-tools')
    metadata = path/'Sparkle.framework/Resources/Info.plist'
    if not metadata.is_file():
        candidates = list(path.glob('Sparkle.xcframework/*/Sparkle.framework/Resources/Info.plist'))
        metadata = candidates[0] if len(candidates) == 1 else metadata
    if not metadata.is_file() or plistlib.loads(metadata.read_bytes()).get('CFBundleShortVersionString') != SPARKLE_VERSION:
        reject('sparkle-tools-version')
    return path

def preflight(requested, note_path, tools):
    errors = []
    def attempt(action, default=None):
        try:
            return action()
        except Rejected as e:
            errors.append(e)
            return default
        except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile):
            errors.append(Rejected('input-format-or-io'))
            return default
    requested_tuple = attempt(lambda: version(requested))
    branch = attempt(lambda: git('symbolic-ref', '--quiet', '--short', 'HEAD'), '')
    if branch != 'main':
        errors.append(Rejected('main-required'))
    dirty = attempt(lambda: git('status', '--porcelain=v1', '--untracked-files=all'), 'unknown')
    if dirty:
        errors.append(Rejected('clean-worktree-required'))
    before = attempt(lambda: read_file(ROOT/'project.yml', 200000))
    settings = attempt(lambda: project_settings(before)) if before is not None else None
    notes = attempt(lambda: notes_text(note_path))
    root = attempt(lambda: tools_root(tools))
    previous_feed = None
    feed_numbers = []
    if (ROOT/'site/appcast.xml').exists() or (ROOT/'site/appcast.xml').is_symlink():
        previous_feed = attempt(lambda: read_file(ROOT/'site/appcast.xml', 2_000_000))
        tree = attempt(lambda: read_xml(previous_feed)) if previous_feed is not None else None
        if tree is not None:
            feed_numbers = attempt(lambda: feed_builds(tree), [])
            attempt(lambda: sensitive(previous_feed.decode('utf-8')))
    history = attempt(records, [])
    result = None
    if settings is not None:
        current, current_build, info = settings
        if not check_package(info):
            errors.append(Rejected('production-package-settings-required'))
        attempt(lambda: repository(info['SUFeedURL']))
        if requested_tuple is not None:
            if requested_tuple < version(current):
                errors.append(Rejected('version-downgrade'))
            if requested_tuple[0] == 0 and requested_tuple[:2] != (0, 9):
                errors.append(Rejected('internal-version-must-be-0.9.x'))
            if version(current)[0] == 0 and requested_tuple[0] > 0 and requested_tuple != (1, 0, 0):
                errors.append(Rejected('first-public-version-must-be-1.0.0'))
            new_build = max([current_build] + feed_numbers + history) + 1
            if new_build > MAX_BUILD:
                errors.append(Rejected('build-overflow'))
            name = f'DoIt-{requested}-{new_build}'
            dist = ROOT/'dist'
            attempt(lambda: safe_path(dist))
            if (dist/name).exists() or (dist/name).is_symlink() or (dist/(name+'.zip')).exists():
                errors.append(Rejected('artifact-already-exists'))
            result = dict(version=requested, build=new_build, current=current, current_build=current_build,
                          info=info, before=before, notes=notes, tools=root, feed=previous_feed,
                          commit=attempt(lambda: git('rev-parse', 'HEAD')), name=name)
    if result and result['commit'] and notes and result['commit'] in notes:
        errors.append(Rejected('source-sha-in-public-notes'))
    return result, errors

def check_tools(plan):
    run(['xcrun', 'swiftc', '-typecheck', ROOT/'scripts/lib/verify_release.swift'], 'signature-verifier-compile')
    for name in ('sign_update', 'generate_keys'):
        run([plan['tools']/'bin'/name, '--help'], 'sparkle-tool-help')
    actual = run([plan['tools']/'bin/generate_keys', '--account', ACCOUNT, '-p'], 'existing-signing-key-required').decode().strip()
    if actual != plan['info']['SUPublicEDKey']:
        reject('public-key-mismatch')
    identities = run(['/usr/bin/security', 'find-identity', '-p', 'codesigning'], 'code-signing-identity')
    if b'"DoIt Self Signing"' not in identities:
        reject('code-signing-identity')

def verify_app(app, info, marketing, build):
    p = safe_path(app)
    plist = plistlib.loads(read_file(p/'Contents/Info.plist', 100000))
    if (plist.get('CFBundleIdentifier') != 'com.personal.doit' or
            plist.get('CFBundleShortVersionString') != marketing or plist.get('CFBundleVersion') != str(build) or
            plist.get('SUPublicEDKey') != info['SUPublicEDKey'] or plist.get('SUFeedURL') != info['SUFeedURL'] or
            plist.get('DoItUpdateValidation') is not False or not check_package(plist) or
            plist.get('LSMinimumSystemVersion') not in ('14.0', '14.0.0')):
        reject('built-app-metadata')
    arches = run(['lipo', '-archs', p/'Contents/MacOS/DoIt'], 'app-architectures').decode().split()
    if set(arches) != {'arm64', 'x86_64'}:
        reject('universal-required')
    # 검증만 재귀 수행한다. 서명을 강제로 다시 씌우지 않는다.
    run(['codesign', '--verify', '--deep', '--strict', p], 'app-nested-signatures')
    details = subprocess.run(['codesign', '-dvv', str(p)], capture_output=True).stderr
    if b'Authority=DoIt Self Signing' not in details:
        reject('app-signing-identity')
    framework = p/'Contents/Frameworks/Sparkle.framework'
    meta = plistlib.loads((framework/'Resources/Info.plist').read_bytes())
    if meta.get('CFBundleShortVersionString') != SPARKLE_VERSION:
        reject('app-sparkle-version')
    for nested in [framework, *list((framework/'Versions/B').glob('**/*.app')), *list((framework/'Versions/B').glob('**/*.xpc'))]:
        run(['codesign', '--verify', '--strict', nested], 'nested-signature')
    return plist

def verify_zip_paths(archive):
    entries = archive.infolist()
    if len(entries) > 10000 or sum(i.file_size for i in entries) > 512*1024*1024:
        reject('archive-size-limit')
    names = set()
    links = []
    for item in entries:
        name = item.filename.rstrip('/')
        p = PurePosixPath(name)
        if (not name or str(p) != name or p.is_absolute() or '..' in p.parts or
                not name.startswith('DoIt.app/') and name != 'DoIt.app' or name in names):
            reject('archive-path')
        names.add(name)
        mode = item.external_attr >> 16
        if stat.S_ISLNK(mode):
            target = archive.read(item).decode('utf-8')
            normalized = posixpath.normpath(posixpath.join(str(p.parent), target))
            if target.startswith('/') or not normalized.startswith('DoIt.app/'):
                reject('archive-link-escape')
            links.append(name + '/')
        elif stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
            reject('archive-special-file')
    if any(name.startswith(link) for link in links for name in names):
        reject('archive-through-symlink')

def verify_signature(public_key, signature, archive):
    run(['xcrun', 'swift', ROOT/'scripts/lib/verify_release.swift', public_key, signature, archive], 'eddsa-verification')

def verify_archive(archive, info, marketing, build, signature):
    safe_path(archive)
    verify_signature(info['SUPublicEDKey'], signature, archive)
    with zipfile.ZipFile(archive) as z:
        verify_zip_paths(z)
    with tempfile.TemporaryDirectory(prefix='doit-release-verify-', dir='/private/tmp') as temp:
        run(['ditto', '-x', '-k', archive, temp], 'archive-extraction')
        verify_app(Path(temp)/'DoIt.app', info, marketing, build)

def candidate(plan, archive, signature):
    ET.register_namespace('sparkle', NS)
    root = read_xml(plan['feed']) if plan['feed'] is not None else ET.Element('rss', version='2.0')
    channel = root.find('channel')
    if channel is None:
        channel = ET.SubElement(root, 'channel')
        ET.SubElement(channel, 'title').text = 'DoIt 업데이트'
    if plan['build'] in feed_builds(root):
        reject('duplicate-appcast-build')
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = 'DoIt ' + plan['version'] + ' 업데이트'
    ET.SubElement(item, 'description').text = plan['notes']
    ET.SubElement(item, TAG+'version').text = str(plan['build'])
    ET.SubElement(item, TAG+'shortVersionString').text = plan['version']
    ET.SubElement(item, TAG+'minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, 'enclosure', {'url': download_url(plan['info'], plan['version'], plan['build']),
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream', TAG+'edSignature': signature})
    channel.insert(0, item)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'

def verify_manifest(path, info):
    if not check_package(info):
        reject('production-package-settings-required')
    path = safe_path(path)
    m = manifest_data(path)
    verify_provenance(m)
    if m['public_key'] != info['SUPublicEDKey'] or m['download_url'] != download_url(info, m['version'], m['build']):
        reject('manifest-key-or-url')
    folder = path.parent
    for key, hkey in (('zip', 'sha256'), ('notes_file', 'notes_sha256'), ('appcast_file', 'appcast_sha256')):
        content = read_file(folder/m[key], 512*1024*1024)
        if sha(content) != m[hkey]:
            reject('manifest-hash-mismatch')
    archive = folder/m['zip']
    if archive.name != f"DoIt-{m['version']}-{m['build']}.zip" or archive.stat().st_size != m['size']:
        reject('manifest-size-or-name')
    root = read_xml(read_file(folder/m['appcast_file'], 2_000_000))
    feed_builds(root)
    matches = [i for i in root.find('channel').findall('item') if item_value(i, 'version') == str(m['build'])]
    if len(matches) != 1:
        reject('manifest-appcast-item')
    item = matches[0]
    enclosure = item.find('enclosure')
    if (enclosure is None or enclosure.get('url') != m['download_url'] or enclosure.get('length') != str(m['size']) or
            enclosure.get(TAG+'edSignature') != m['ed25519_signature'] or
            item_value(item, 'shortVersionString') != m['version'] or
            item.findtext(TAG+'minimumSystemVersion') != '14.0.0' or
            item.findtext('description') != notes_text(folder/m['notes_file'])):
        reject('manifest-appcast-mismatch')
    verify_archive(archive, info, m['version'], m['build'], m['ed25519_signature'])
    return m

@contextlib.contextmanager
def lock():
    directory = Path(git('rev-parse', '--git-common-dir'))
    if not directory.is_absolute():
        directory = ROOT/directory
    file = directory/'doit-release.lock'
    fd = os.open(file, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        s = os.fstat(fd)
        if s.st_uid != os.getuid() or s.st_nlink != 1 or not stat.S_ISREG(s.st_mode):
            reject('lock-file')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            reject('release-already-running')
        yield
    finally:
        os.close(fd)  # lock inode는 유지하고 모든 경로에서 운영체제 lock을 해제한다.

def publish_directory(source, destination):
    # macOS public renamex_np(RENAME_EXCL), sys/stdio.h: 목적지가 있으면 원자적으로 거부.
    api = ctypes.CDLL(None, use_errno=True).renamex_np
    api.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    api.restype = ctypes.c_int
    safe_path(destination.parent)
    if api(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        reject('artifact-already-exists' if ctypes.get_errno() == errno.EEXIST else 'atomic-publication-failed')

def replace_project(path, data, mode):
    fd, name = tempfile.mkstemp(prefix='.doit-release-project-', dir=str(ROOT))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def prepare(plan):
    check_tools(plan)  # 키 존재·공개 키 일치를 파일 변경 전에 확인한다. 생성·회전·내보내기 없음.
    for old in (ROOT/'dist').glob('DoIt-*/release.manifest.json'):
        verify_manifest(old, plan['info'])
    project = ROOT/'project.yml'
    before = plan['before']
    mode = stat.S_IMODE(project.stat().st_mode)
    patched = patched_project(before,plan['version'],plan['build'])
    dist = ROOT/'dist'
    had_dist = dist.exists()
    stage = None
    changed = False
    success = False
    template_before = read_file(ROOT/'DoIt/Resources/Info.plist', 100000)
    try:
        if read_file(project,200000) != before:
            reject('project-edited-before-change')
        replace_project(project, patched, mode)
        changed = True
        run(['xcodegen', 'generate'], 'xcodegen-failed')
        run(['xcodebuild', '-project', 'DoIt.xcodeproj', '-scheme', 'DoIt', '-configuration', 'Release',
             '-derivedDataPath', 'build', 'build'], 'release-build-failed')
        app = ROOT/'build/Build/Products/Release/DoIt.app'
        verify_app(app, plan['info'], plan['version'], plan['build'])
        dist.mkdir(exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.doit-release-stage-', dir=str(dist)))
        archive = stage/(plan['name']+'.zip')
        run([ROOT/'scripts/package.sh', '--app', app, '--output', archive], 'package-failed')
        signature = run([plan['tools']/'bin/sign_update', '--account', ACCOUNT, '-p', archive], 'signing-failed').decode().strip()
        if len(base64.b64decode(signature, validate=True)) != 64:
            reject('signature-format')
        run([plan['tools']/'bin/sign_update', '--account', ACCOUNT, '--verify', archive, signature], 'sparkle-verification')
        (stage/'release-notes.md').write_text(plan['notes'], encoding='utf-8')
        feed = candidate(plan, archive, signature)
        (stage/'appcast-candidate.xml').write_bytes(feed)
        m = dict(schema=1, source_commit=plan['commit'], source_version={'version':plan['current'], 'build':plan['current_build']},
                 version=plan['version'], build=plan['build'], zip=archive.name, size=archive.stat().st_size,
                 sha256=sha(archive.read_bytes()), ed25519_signature=signature, public_key=plan['info']['SUPublicEDKey'],
                 download_url=download_url(plan['info'], plan['version'], plan['build']), minimum_os='14.0.0',
                 notes_file='release-notes.md', notes_sha256=sha((stage/'release-notes.md').read_bytes()),
                 appcast_file='appcast-candidate.xml', appcast_sha256=sha(feed),
                 project_before_sha256=sha(before), project_after_sha256=sha(patched), sparkle_version=SPARKLE_VERSION)
        manifest = stage/'release.manifest.json'
        manifest.write_text(json.dumps(m, ensure_ascii=False, indent=2, sort_keys=True)+'\n', encoding='utf-8')
        verify_manifest(manifest, plan['info'])  # 최종 zip을 독립적으로 재추출·암호 검증한다.
        if (read_file(project,200000) != patched or git('rev-parse','HEAD') != plan['commit'] or
                read_file(ROOT/'DoIt/Resources/Info.plist',100000) != template_before or
                git('diff','--name-only') != 'project.yml' or git('diff','--cached','--name-only') or
                git('status','--porcelain=v1','--untracked-files=all') != 'M project.yml'):
            reject('source-changed-during-release')
        if (read_file(ROOT/'site/appcast.xml',2_000_000) if (ROOT/'site/appcast.xml').exists() else None) != plan['feed']:
            reject('site-changed-during-release')
        destination = dist/plan['name']
        if destination.exists() or destination.is_symlink():
            reject('artifact-already-exists')
        publish_directory(stage, destination)
        stage = None
        success = True
        print(f"로컬 후보 준비 완료: {plan['version']}({plan['build']}) 원본 SHA={plan['commit']}")
        print('산출물: dist/'+plan['name']+'/ (zip, release.manifest.json, appcast-candidate.xml, release-notes.md)')
        print('site/appcast.xml·Git 커밋/태그·설치본·원격은 바꾸지 않았어요. 버전 diff와 후보를 검토하세요.')
        print('다음 순서: zip 업로드 → 다운로드 파일·hash·서명 확인 → appcast 후보를 site에 반영·공개.')
    finally:
        if not success and changed:
            try:
                current = read_file(project,200000)
            except (OSError, Rejected):
                current = None
            if current == patched:
                replace_project(project, before, mode)
            else:
                print('release-error=external-project-edit-preserved count=1',file=sys.stderr)
        if stage is not None:
            shutil.rmtree(stage)
        if not had_dist and dist.exists():
            try: dist.rmdir()
            except OSError: pass  # 기존/다른 산출물은 삭제하지 않는다.

def main():
    class SafeParser(argparse.ArgumentParser):
        def error(self, message):
            reject('invalid-arguments')
    parser = SafeParser(description='로컬 zip·manifest·appcast 후보 준비. 게시/설치 없음.')
    parser.add_argument('version', nargs='?')
    parser.add_argument('--notes')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--sparkle-tools')
    parser.add_argument('--verify', metavar='MANIFEST')
    args = parser.parse_args()
    if args.verify:
        if args.version or args.notes or args.dry_run:
            reject('invalid-arguments')
        _, _, info = project_settings(read_file(ROOT/'project.yml', 200000))
        verify_manifest(Path(args.verify), info)
        print('로컬 manifest·appcast·zip·앱·서명 대조 통과. 업로드 확인은 별도입니다.')
        return 0
    if not args.version or not args.notes:
        reject('version-and-notes-required')
    if args.dry_run:
        plan, errors = preflight(args.version, args.notes, args.sparkle_tools)
        print('dry-run: 읽기만 수행; 파일·Git·키체인·네트워크 변경 없음')
        if plan:
            print(f"현재={plan['current']}({plan['current_build']}) 예정={plan['version']}({plan['build']})")
            print('예정 산출물: dist/'+plan['name']+'/ zip·manifest·appcast 후보·노트')
        print('필요: 깨끗한 main, 정식 Pages HTTPS·공개 키, Sparkle 2.10.1 도구·기존 전용 키, 자체 서명 인증서')
        for e in errors:
            print(f'release-block={e.rule} count={e.count}')
        print('서명 키 존재·인증서·실제 빌드는 실제 실행에서 확인합니다.')
        return 1 if errors else 0
    with lock():
        plan, errors = preflight(args.version, args.notes, args.sparkle_tools)
        if errors:
            for e in errors:
                print(f'release-block={e.rule} count={e.count}',file=sys.stderr)
            return 1
        prepare(plan)
    return 0

if __name__ == '__main__':
    def interrupted(signum, frame):
        reject('interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main())
    except Rejected as error:
        print(f'release-error={error.rule} count={error.count}',file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, UnicodeError, TypeError, KeyError, zipfile.BadZipFile):
        print('release-error=format-or-io count=1',file=sys.stderr)
        sys.exit(1)
