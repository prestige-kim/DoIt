#!/usr/bin/python3
"""일회용 loopback 업데이트 시험 자료. 개인 키는 키체인에서만 sign_update가 사용."""
import base64
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ACCOUNT = 'com.personal.doit.updates'
BASE = 'http://127.0.0.1:8765/'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'

def command(args):
    result = subprocess.run([str(x) for x in args], capture_output=True)
    if result.returncode:
        raise RuntimeError('validation tool failed; private output suppressed')
    return result.stdout.decode().strip()

def workdir(text):
    p = Path(text)
    if p.is_symlink() or not p.is_absolute() or p.resolve().parent != Path('/private/tmp') or not p.name.startswith('doit-update-validation-'):
        raise ValueError('temporary directory required')
    if (p / '.doit-validation-root').read_text().strip() != str(p):
        raise ValueError('validation marker required')
    return p

def feed(work, name, archive, signature, build='9'):
    ET.register_namespace('sparkle', NS)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'DoIt local update validation'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Local validation build ' + build
    ET.SubElement(item, '{'+NS+'}version').text = build
    ET.SubElement(item, '{'+NS+'}shortVersionString').text = '0.9.2'
    ET.SubElement(item, '{'+NS+'}minimumSystemVersion').text = '14.0'
    ET.SubElement(item, 'enclosure', {'url': BASE+archive.name, 'length': str(archive.stat().st_size),
                                    'type': 'application/octet-stream', '{'+NS+'}edSignature': signature})
    ET.ElementTree(rss).write(work / (name+'.xml'), encoding='utf-8', xml_declaration=True)

def archives(work, tools, source, prefix):
    zipfile = work / (prefix+'good.zip')
    command(['ditto', '-c', '-k', '--keepParent', source, zipfile])
    signature = command([tools/'bin/sign_update', '--account', ACCOUNT, '-p', zipfile])
    command([tools/'bin/sign_update', '--account', ACCOUNT, '--verify', zipfile, signature])
    feed(work, prefix+'good', zipfile, signature)
    feed(work, prefix+'bad-signature', zipfile, base64.b64encode(bytes(64)).decode())
    altered = work/(prefix+'tampered.zip')
    shutil.copy2(zipfile, altered)
    with altered.open('ab') as f: f.write(b'local validation mutation')
    feed(work, prefix+'tampered', altered, signature)
    changed = work/(prefix+'different-code')/source.name
    changed.parent.mkdir(exist_ok=True)
    command(['ditto', source, changed])
    # 시험 사본의 앱 본체만 ad hoc 재서명. 정식 앱·중첩 서명·기존 설치본은 건드리지 않음.
    command(['codesign', '--force', '--sign', '-', changed])
    command(['codesign', '--verify', '--strict', changed])
    other_zip = work/(prefix+'different-code.zip')
    command(['ditto', '-c', '-k', '--keepParent', changed, other_zip])
    other_sig = command([tools/'bin/sign_update', '--account', ACCOUNT, '-p', other_zip])
    feed(work, prefix+'different-code', other_zip, other_sig)

FIXTURE_SOURCE = r'''
import AppKit
@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var updates: UpdateService?
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ note: Notification) {
        let configuration = UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:], permitsLocal: true)
        let updates = UpdateService(configuration: configuration, driver: SparkleUpdateDriver(configuration: configuration))
        self.updates = updates
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Update Fixture"
        let menu = NSMenu()
        let check = NSMenuItem(title: "업데이트 확인…", action: #selector(checkUpdate), keyEquivalent: "")
        check.target = self; menu.addItem(check)
        let quit = NSMenuItem(title: "시험 앱 종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu; self.item = item
        updates.checkForUpdates()
    }
    @objc func checkUpdate() { updates?.checkForUpdates() }
    @objc func quitApp() { NSApp.terminate(nil) }
}
@main struct Fixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
'''

def main():
    action, raw = sys.argv[1:3]
    work = workdir(raw)
    if action in ('prepare', 'fixture'):
        tools = Path(sys.argv[3]).resolve()
        if not (tools/'bin/sign_update').is_file():
            raise ValueError('official signing tool required')
        if action == 'prepare':
            archives(work, tools, work/'DoIt-9.app', '')
            shutil.copy2(work/'good.xml', work/'appcast.xml')
        else:
            root = Path(__file__).resolve().parents[2]
            mainfile = work/'Fixture.swift'; mainfile.write_text(FIXTURE_SOURCE)
            for version in ('8','9'):
                app = work/('fixture-'+version)/'DoIt Update Fixture.app'
                (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
                (app/'Contents/Frameworks').mkdir(exist_ok=True)
                source = work/('DoIt-'+version+'.app')
                with (source/'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
                info.update(CFBundleIdentifier='com.personal.doit.update-fixture', CFBundleExecutable='DoItUpdateFixture',
                            CFBundleName='DoIt Update Fixture', CFBundleVersion=version)
                with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
                command(['ditto',source/'Contents/Frameworks/Sparkle.framework',app/'Contents/Frameworks/Sparkle.framework'])
                command(['xcrun','swiftc','-parse-as-library','-swift-version','5','-O','-D','UPDATE_VALIDATION',
                         '-F',tools,'-framework','Sparkle',
                         '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
                         mainfile,*sorted((root/'DoIt/Updates').glob('*.swift')),
                         '-o',app/'Contents/MacOS/DoItUpdateFixture'])
                command(['codesign','--force','--sign','DoIt Self Signing',app])
                command(['codesign','--verify','--strict',app])
            archives(work,tools,work/'fixture-9/DoIt Update Fixture.app','fixture-')
            shutil.copy2(work/'fixture-good.xml',work/'appcast.xml')
        print('로컬 검증 자료 준비 완료. 앱 실행·기존 설치본 교체는 하지 않았어요.')
    elif action == 'feed':
        name = sys.argv[3]
        if name not in {p+c for p in ('','fixture-') for c in ('good','bad-signature','tampered','different-code')}:
            raise ValueError('unknown validation case')
        shutil.copy2(work/(name+'.xml'),work/'appcast.xml')
        print('검증 feed 선택:',name)
    elif action == 'serve':
        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(work),**kwargs)
            def log_message(self,*args): pass
            def do_GET(self):
                # XML·서명 zip만 제공. 앱·빌드 로그·상태·기타 파일에는 접근 불가.
                if self.path != '/appcast.xml' and self.path not in {'/'+p.name for p in work.glob('*.zip')}:
                    self.send_error(404);return
                super().do_GET()
            def do_HEAD(self): self.send_error(405)
        with http.server.HTTPServer(('127.0.0.1',8765),Handler) as server:
            print('loopback 검증 서버 실행 중. Ctrl-C로 이 서버만 종료합니다.',flush=True)
            try: server.serve_forever()
            except KeyboardInterrupt: pass
    else: raise ValueError('unknown command')

if __name__ == '__main__':
    try: main()
    except (ValueError,OSError,RuntimeError):
        print('로컬 검증 도구 실패. 원문 경로·개인 키 관련 출력은 숨겼어요.',file=sys.stderr)
        sys.exit(1)
