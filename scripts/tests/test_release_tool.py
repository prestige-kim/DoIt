"""임시 저장소 회귀: 빌드·서명은 mock이며 실 배포 검증이 아니다. 저장소 루트에서 실행."""
import base64, contextlib, copy, hashlib, importlib.util, io, json, os
from pathlib import Path
import plistlib, shutil, signal, subprocess, sys, tempfile, unittest, zipfile
sys.path.insert(0,str(Path.cwd()/'scripts/lib'))
spec=importlib.util.spec_from_file_location('release_tool',Path.cwd()/'scripts/lib/release_tool.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
SOURCE=Path.cwd();ORIGINAL_RUN=r.run
PROJECT=(SOURCE/'project.yml').read_text();TEMPLATE=plistlib.loads((SOURCE/'DoIt/Resources/Info.plist').read_bytes())
SIG=base64.b64encode(b'v'*64).decode()
class ReleaseTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='doit-release-unit-',dir='/private/tmp');self.root=Path(self.temp.name)
  r.ROOT=self.root
  (self.root/'DoIt/Resources').mkdir(parents=True)
  project=PROJECT.replace('https://prestige-kim.github.io/DoIt/appcast.xml','https://example.github.io/DoIt/appcast.xml').replace('DoItDistributionEnabled: false','DoItDistributionEnabled: true')
  (self.root/'project.yml').write_text(project)
  template=copy.deepcopy(TEMPLATE);template['SUFeedURL']='https://example.github.io/DoIt/appcast.xml';template['DoItDistributionEnabled']=True
  (self.root/'DoIt/Resources/Info.plist').write_bytes(plistlib.dumps(template))
  self.tools=self.root/'build/tools';(self.tools/'bin').mkdir(parents=True)
  (self.tools/'Sparkle.framework/Resources').mkdir(parents=True)
  (self.tools/'Sparkle.framework/Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'2.10.1'}))
  for name in ('sign_update','generate_keys'):
   p=self.tools/'bin'/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o755)
  (self.root/'.gitignore').write_text('build/\ndist/\n')
  (self.root/'notes.md').write_text('가짜 변경 <태그> & "따옴표"\n')
  self.git('init','-b','main');self.git('config','user.name','Release Fixture');self.git('config','user.email','release'+'@'+'example.invalid')
  self.git('add','.');self.git('commit','-qm','fixture')
  self.original=(self.root/'project.yml').read_bytes();self.fail=None;self.external=False;self.calls=[]
  self.saved=(r.run,r.check_tools,r.verify_app,r.verify_signature)
  r.run=self.fake_run;r.check_tools=lambda plan: None;r.verify_app=self.fake_verify_app;r.verify_signature=lambda *args: None
 def tearDown(self):
  r.run,r.check_tools,r.verify_app,r.verify_signature=self.saved;r.ROOT=SOURCE;self.temp.cleanup()
 def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),*args],stderr=subprocess.DEVNULL).decode().strip()
 def fake_run(self,args,rule,cwd=None):
  self.calls.append(rule)
  if rule==self.fail:
   if self.external:(self.root/'project.yml').write_bytes((self.root/'project.yml').read_bytes()+b'# external edit\n')
   r.reject(rule)
  if str(args[0])=='git':return ORIGINAL_RUN(args,rule,cwd)
  if rule=='release-build-failed':
   version,build,info=r.project_settings((self.root/'project.yml').read_bytes())
   app=self.root/'build/Build/Products/Release/DoIt.app';(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
   p=dict(info,CFBundleIdentifier='com.personal.doit',CFBundleVersion=str(build),CFBundleShortVersionString=version,LSMinimumSystemVersion='14.0')
   (app/'Contents/Info.plist').write_bytes(plistlib.dumps(p));(app/'Contents/MacOS/DoIt').write_bytes(b'fake universal binary')
  if rule=='package-failed':
   app=Path(args[2]);destination=Path(args[4])
   with zipfile.ZipFile(destination,'w') as z:
    for p in app.rglob('*'):
     if p.is_file():z.write(p,'DoIt.app/'+str(p.relative_to(app)))
  if rule=='signing-failed':return SIG.encode()
  if rule=='archive-extraction':
   with zipfile.ZipFile(args[3]) as z:z.extractall(args[4])
  return b''
 def fake_verify_app(self,app,info,marketing,build):
  p=plistlib.loads((Path(app)/'Contents/Info.plist').read_bytes())
  if p['CFBundleVersion']!=str(build) or p['CFBundleShortVersionString']!=marketing:r.reject('fake-app-metadata')
  return p
 def plan(self,version='0.9.3',notes=None):
  return r.preflight(version,notes or self.root/'notes.md',self.tools)
 def ready(self):
  p,e=self.plan();self.assertEqual(e,[]);return p
 def prepare(self):
  with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):r.prepare(self.ready())
  return next((self.root/'dist').glob('DoIt-*'))
 def unchanged(self):self.assertEqual((self.root/'project.yml').read_bytes(),self.original)
 def blocked(self,rule,version='0.9.3',notes=None):
  _,errors=self.plan(version,notes);self.assertIn(rule,[e.rule for e in errors]);self.unchanged()
 def rewrite(self,key,value):
  s=(self.root/'project.yml').read_text();old=r.scalar(s,key)
  old_text=str(old).lower() if type(old)is bool else str(old)
  import re
  s=re.sub(r'^(\s*'+key+r':) [^\n]+$',lambda m:m[1]+' '+json.dumps(value,ensure_ascii=False),s,flags=re.M)
  (self.root/'project.yml').write_text(s)
  p=plistlib.loads((self.root/'DoIt/Resources/Info.plist').read_bytes());p[key]=value
  (self.root/'DoIt/Resources/Info.plist').write_bytes(plistlib.dumps(p))
  self.git('add','.');self.git('commit','-qm','configuration');self.original=(self.root/'project.yml').read_bytes()
 def test_distribution_disabled(self):
  self.rewrite('DoItDistributionEnabled',False);self.blocked('production-package-settings-required')
 def test_distribution_wrong_type(self):
  self.rewrite('DoItDistributionEnabled','true');self.blocked('project-policy-type')
 def test_manifest_verification_requires_distribution_gate(self):
  folder=self.prepare();info=self.ready_info();info['DoItDistributionEnabled']=False
  with self.assertRaises(r.Rejected) as ex:r.verify_manifest(folder/'release.manifest.json',info)
  self.assertEqual(ex.exception.rule,'production-package-settings-required')
 def test_clean_main_plan(self):self.assertEqual(self.ready()['build'],11)
 def test_work_branch_rejected(self):self.git('switch','-c','work');self.blocked('main-required')
 def test_staged_dirty(self):self.root.joinpath('notes.md').write_text('변경');self.git('add','notes.md');self.blocked('clean-worktree-required')
 def test_unstaged_dirty(self):self.root.joinpath('notes.md').write_text('변경');self.blocked('clean-worktree-required')
 def test_untracked_dirty(self):self.root.joinpath('new.txt').write_text('가짜');self.blocked('clean-worktree-required')
 def test_ignored_build_is_allowed(self):self.root.joinpath('build/ignored').write_text('safe');self.ready()
 def test_strict_versions(self):
  for v in ('01.0.0','0.9','0.9.3-beta','0.9.3+meta','bad','0.9.3/path'):self.blocked('invalid-version',v)
 def test_version_downgrade(self):self.blocked('version-downgrade','0.9.1')
 def test_same_marketing_version(self):self.assertEqual(self.plan('0.9.2')[0]['build'],11)
 def test_first_public_version(self):self.blocked('first-public-version-must-be-1.0.0','1.1.0');self.assertEqual(self.plan('1.0.0')[1],[])
 def test_placeholder(self):self.rewrite('SUFeedURL','https://updates.example.invalid/appcast.xml');self.blocked('production-package-settings-required')
 def test_wrong_feed_forms(self):
  for url in ('http://example.github.io/DoIt/appcast.xml','https://example.github.io/DoIt/appcast.xml?x=1','https://other.org/appcast.xml','https://me:@example.github.io/DoIt/appcast.xml'):
   self.rewrite('SUFeedURL',url);self.blocked('feed-policy')
 def test_validation_mode(self):self.rewrite('DoItUpdateValidation',True);self.blocked('production-package-settings-required')
 def test_bad_public_key(self):self.rewrite('SUPublicEDKey','invalid');self.blocked('production-package-settings-required')
 def test_empty_and_bad_encoding_notes(self):
  for data in (b'',b'\xff',b'English only'):
   self.root.joinpath('notes.md').write_bytes(data);self.blocked('notes-encoding' if data==b'\xff' else 'notes-empty-or-not-korean')
 def test_sensitive_notes_no_values_printed(self):
  for text in ('가짜 /Users/'+'invented/file','가짜 person'+'@'+'privacy.invalid','가짜 ghp_'+'Z'*30,'가짜 '+'-----BEGIN '+'PRIVATE KEY-----','가짜 /feeds/calendars/'+'SECRET'):
   self.root.joinpath('notes.md').write_text(text)
   output=io.StringIO()
   with contextlib.redirect_stdout(output),contextlib.redirect_stderr(output):_,errors=self.plan()
   self.assertTrue(any(e.rule in r.SENSITIVE for e in errors));self.assertEqual(output.getvalue(),'')
 def test_notes_forbidden_path_without_read(self):
  p=self.root/'other.ics';p.write_text('never read');self.blocked('notes-forbidden-path',notes=p)
 def test_notes_symlink(self):
  p=self.root/'alias.md';p.symlink_to(self.root/'notes.md');self.blocked('symlink-input',notes=p)
 def test_source_sha_not_in_notes(self):
  self.root.joinpath('notes.md').write_text('가짜 '+self.git('rev-parse','HEAD'));self.blocked('source-sha-in-public-notes')
 def test_tool_version(self):
  self.tools.joinpath('Sparkle.framework/Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'2.9.5'}));self.blocked('sparkle-tools-version')
 def feed(self,builds):
  root=r.ET.Element('rss',version='2.0');ch=r.ET.SubElement(root,'channel')
  for n in builds:
   item=r.ET.SubElement(ch,'item');r.ET.SubElement(item,r.TAG+'version').text=str(n);r.ET.SubElement(item,r.TAG+'shortVersionString').text='0.9.2';r.ET.SubElement(item,'title').text='기존 항목'
  p=self.root/'site/appcast.xml';p.parent.mkdir(exist_ok=True);p.write_bytes(r.ET.tostring(root));self.git('add','site');self.git('commit','-qm','feed')
 def test_maximum_feed_build(self):self.feed([30]);self.assertEqual(self.ready()['build'],31)
 def test_duplicate_feed_rejected(self):self.feed([20,20]);self.blocked('duplicate-appcast-build')
 def test_invalid_xml_and_entity(self):
  self.feed([20]);p=self.root/'site/appcast.xml'
  for content in (b'broken',b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///forbidden">]><rss version="2.0"><channel/></rss>'):
   p.write_bytes(content);_,errors=self.plan();self.assertTrue(any(e.rule in ('invalid-appcast','xml-doctype-or-entity') for e in errors))
 def test_success_and_manifest_independent_match(self):
  folder=self.prepare();m=r.verify_manifest(folder/'release.manifest.json',self.ready_info())
  self.assertEqual(m['build'],11);self.assertEqual(m['source_commit'],self.git('rev-parse','HEAD'));self.assertEqual(m['size'],(folder/m['zip']).stat().st_size)
  self.assertFalse((self.root/'site').exists());self.assertEqual(self.git('diff','--name-only'),'project.yml')
 def ready_info(self):return r.project_settings((self.root/'project.yml').read_bytes())[2]
 def test_existing_items_and_xml_escape_preserved(self):
  self.feed([20]);before=(self.root/'site/appcast.xml').read_bytes();folder=self.prepare();root=r.read_xml((folder/'appcast-candidate.xml').read_bytes())
  self.assertEqual(r.feed_builds(root),[21,20]);self.assertEqual((self.root/'site/appcast.xml').read_bytes(),before)
  self.assertEqual(root.find('channel/item/description').text,(self.root/'notes.md').read_text());self.assertIn(b'&lt;', (folder/'appcast-candidate.xml').read_bytes())
 def test_build_failure_rollback(self):
  self.fail='release-build-failed'
  with self.assertRaises(r.Rejected):self.prepare()
  self.unchanged();self.assertFalse((self.root/'dist').exists())
 def test_package_failure_rollback(self):
  self.fail='package-failed'
  with self.assertRaises(r.Rejected):self.prepare()
  self.unchanged();self.assertFalse((self.root/'dist').exists())
 def test_signature_failure_rollback_preserves_old_files(self):
  (self.root/'dist').mkdir();(self.root/'dist/keep.txt').write_text('keep');self.fail='signing-failed'
  with self.assertRaises(r.Rejected):self.prepare()
  self.unchanged();self.assertEqual((self.root/'dist/keep.txt').read_text(),'keep');self.assertEqual(len(list((self.root/'dist').iterdir())),1)
 def test_key_mismatch_before_mutation(self):
  def fail(plan):r.reject('public-key-mismatch')
  r.check_tools=fail
  with self.assertRaises(r.Rejected):self.prepare()
  self.unchanged();self.assertNotIn('xcodegen-failed',self.calls)
 def test_external_edit_not_overwritten(self):
  self.fail='release-build-failed';self.external=True
  with self.assertRaises(r.Rejected):self.prepare()
  self.assertTrue((self.root/'project.yml').read_bytes().endswith(b'# external edit\n'))
  self.assertIn(b'CURRENT_PROJECT_VERSION: "11"',(self.root/'project.yml').read_bytes())
 def test_lock_nonblocking_and_released(self):
  with r.lock():
   with self.assertRaises(r.Rejected) as ex:
    with r.lock():pass
   self.assertEqual(ex.exception.rule,'release-already-running')
  with r.lock():pass
 def test_atomic_publication_collision(self):
  a=self.root/'a';b=self.root/'b';a.mkdir();b.mkdir();(a/'new').write_text('new')
  with self.assertRaises(r.Rejected):r.publish_directory(a,b)
  self.assertTrue(a.exists());self.assertEqual(list(b.iterdir()),[])
 def test_bad_record_does_not_guess_or_overwrite(self):
  p=self.root/'dist/DoIt-0.9.3-11';p.mkdir(parents=True);(p/'keep').write_text('keep')
  self.blocked('input-format-or-io');self.assertEqual((p/'keep').read_text(),'keep')
 def test_history_build_increases(self):
  self.prepare();self.git('add','project.yml');self.git('commit','-qm','version change')
  self.assertEqual(self.ready()['build'],12)
 def test_manifest_hash_size_and_xml_mismatch(self):
  folder=self.prepare();path=folder/'release.manifest.json';original=path.read_bytes();m=json.loads(original)
  for field,value in [('size',m['size']+1),('sha256','0'*64),('download_url','https://github.com/wrong/repo/releases/download/v0.9.3-11/DoIt-0.9.3-11.zip')]:
   changed=copy.deepcopy(m);changed[field]=value;path.write_text(json.dumps(changed))
   with self.assertRaises(r.Rejected):r.verify_manifest(path,self.ready_info())
  path.write_bytes(original);candidate=folder/m['appcast_file'];candidate.write_bytes(candidate.read_bytes().replace(b'length="',b'length="9',1))
  m['appcast_sha256']=r.sha(candidate.read_bytes());path.write_text(json.dumps(m))
  with self.assertRaises(r.Rejected):r.verify_manifest(path,self.ready_info())
 def test_tampered_zip_rejected(self):
  folder=self.prepare();path=folder/'release.manifest.json';m=json.loads(path.read_text())
  with (folder/m['zip']).open('ab') as f:f.write(b'tamper')
  with self.assertRaises(r.Rejected):r.verify_manifest(path,self.ready_info())
 def test_archive_path_escape_rejected(self):
  for name in ('../escape','DoIt.app/../escape','other.app/file'):
   p=self.root/'build/test.zip'
   with zipfile.ZipFile(p,'w') as z:z.writestr(name,'fake')
   with zipfile.ZipFile(p) as z:
    with self.assertRaises(r.Rejected):r.verify_zip_paths(z)
 def test_dry_run_does_not_execute_or_mutate(self):
  before=(self.root/'project.yml').read_bytes();status=self.git('status','--porcelain');index=(self.root/'.git/index').read_bytes()
  old=sys.argv;sys.argv=['release','0.9.3','--notes',str(self.root/'notes.md'),'--sparkle-tools',str(self.tools),'--dry-run']
  try:
   with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(r.main(),0)
  finally:sys.argv=old
  self.assertEqual(before,(self.root/'project.yml').read_bytes());self.assertEqual(status,self.git('status','--porcelain'));self.assertEqual(index,(self.root/'.git/index').read_bytes());self.assertFalse((self.root/'.git/doit-release.lock').exists())
  self.assertTrue(all(call=='git-read' for call in self.calls))
 def test_manifest_source_and_diff_hashes(self):
  folder=self.prepare();path=folder/'release.manifest.json';original=path.read_bytes();m=json.loads(original)
  for field,value in [('source_commit','0'*40),('project_before_sha256','0'*64),('project_after_sha256','0'*64)]:
   changed=copy.deepcopy(m);changed[field]=value;path.write_text(json.dumps(changed))
   with self.assertRaises(r.Rejected):r.verify_manifest(path,self.ready_info())
 def test_duplicate_manifest_keys_rejected(self):
  folder=self.prepare();path=folder/'release.manifest.json';data=path.read_text()
  path.write_text('{"schema":1,'+data[1:])
  with self.assertRaises(r.Rejected) as ex:r.manifest_data(path)
  self.assertEqual(ex.exception.rule,'duplicate-json-key')
 def test_lock_released_after_failed_transaction(self):
  self.fail='package-failed'
  with self.assertRaises(r.Rejected):
   with r.lock():self.prepare()
  self.unchanged()
  with r.lock():pass
if __name__=='__main__':unittest.main(verbosity=1)
