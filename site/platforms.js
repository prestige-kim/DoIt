import { startWindowsDemo } from './windows-demo.js?v=20261118-app';
import { verifiedWindowsDownload, verifiedWindowsPreview } from './windows-download.js';

const tabs = ['mac', 'windows'].map((platform) => ({
  platform,
  button: document.getElementById(`tab-${platform}`),
  panel: document.getElementById(`platform-${platform}`),
}));
const heroCopy = document.getElementById('platform-hero-copy');
const heroDemo = document.getElementById('platform-hero-demo');
const switcher = document.getElementById('platform-switch');
const windowsDemo = startWindowsDemo();
let selected = 'mac';

function activate(platform, focus = false) {
  selected = platform;
  const windows = platform === 'windows';
  for (const tab of tabs) {
    const active = tab.platform === platform;
    tab.button.setAttribute('aria-selected', String(active));
    tab.button.tabIndex = active ? 0 : -1;
    tab.panel.hidden = !active;
    if (active && focus) tab.button.focus();
  }
  heroCopy.textContent = windows ? 'Windows용 할 일 앱 DoIt' : 'Mac용 할 일 앱 DoIt';
  for (const link of document.querySelectorAll('[data-platform-link]')) {
    link.setAttribute('href', `#${windows ? 'windows-' : ''}${link.dataset.platformLink}`);
  }
}

function choose(platform) {
  const fromHash = platformFromHash();
  if (fromHash && fromHash !== platform) history.replaceState(null, '', '#platform-switch');
  activate(platform, true);
}

function platformFromHash() {
  if (['#windows-experience', '#windows-install'].includes(location.hash)) return 'windows';
  if (['#experience', '#install'].includes(location.hash)) return 'mac';
  return null;
}

for (const [index, { platform, button }] of tabs.entries()) {
  button.addEventListener('click', () => choose(platform));
  button.addEventListener('keydown', (event) => {
    const nextIndex = { ArrowLeft: 1 - index, ArrowRight: 1 - index, Home: 0, End: 1 }[event.key];
    if (nextIndex === undefined) return;
    event.preventDefault();
    choose(tabs[nextIndex].platform);
  });
}
addEventListener('hashchange', () => {
  const target = platformFromHash();
  if (target && target !== selected) activate(target);
});
heroDemo.addEventListener('click', () => {
  if (selected === 'windows') windowsDemo.open();
});
switcher.hidden = false;
const initial = platformFromHash();
activate(initial ?? 'mac');
if (initial === 'windows') document.querySelector(location.hash).scrollIntoView();

const preview = verifiedWindowsPreview(globalThis.DOIT_WINDOWS_PREVIEW);
const release = preview ?? verifiedWindowsDownload();
if (release) {
  const checksumValues = document.getElementById('windows-checksum-values');
  for (const asset of release.assets) {
    const link = document.getElementById(`windows-download-${asset.architecture}`);
    link.href = asset.url;
    if (preview) link.download = asset.file;
    link.hidden = false;
    const row = document.createElement('p');
    const label = document.createElement('strong');
    const hash = document.createElement('code');
    label.textContent = `${asset.architecture === 'x64' ? 'x64' : 'Arm64'} `;
    hash.textContent = asset.sha256;
    row.append(label, hash);
    checksumValues.append(row);
  }
  document.getElementById('windows-release-message').textContent = `${preview ? '검증용 · ' : ''}DoIt ${release.version} (${release.build}) · Windows 11`;
  document.getElementById('windows-downloads').hidden = false;
  document.getElementById('windows-checksums').hidden = false;
}
