import { SITE_CONFIG } from './config.js';

// Public release metadata is enabled only after both the asset and its URL are verified.
export const WINDOWS_RELEASE = Object.freeze({ releasePublished: false, version: null, build: null, assets: {} });
const architectures = ['x64', 'arm64'];
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

function collectAssets(release, expectedUrl) {
  if (!release || typeof release.version !== 'string' || !versionPattern.test(release.version)
      || !Number.isSafeInteger(release.build) || release.build < 1 || !release.assets) return null;

  const assets = architectures.flatMap((architecture) => {
    const file = `DoIt-Windows-${release.version}-${release.build}-${architecture}-Setup.exe`;
    const url = expectedUrl(file);
    const asset = release.assets[architecture];
    if (!asset || asset.url !== url || typeof asset.sha256 !== 'string' || !/^[0-9a-f]{64}$/i.test(asset.sha256)) return [];
    return [{ architecture, file, url, sha256: asset.sha256.toLowerCase() }];
  });
  return assets.length ? { version: release.version, build: release.build, assets } : null;
}

export function verifiedWindowsDownload(release = WINDOWS_RELEASE, site = SITE_CONFIG) {
  if (release?.releasePublished !== true || typeof site.owner !== 'string' || typeof site.repository !== 'string'
      || !/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/.test(site.owner)
      || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(site.repository)
      || /example|placeholder|your-owner|your-repo|demo/i.test(`${site.owner}/${site.repository}`)) return null;
  return collectAssets(release, (file) =>
    `https://github.com/${site.owner}/${site.repository}/releases/download/windows-v${release.version}-${release.build}/${file}`);
}

export function verifiedWindowsPreview(release) {
  return collectAssets(release, (file) => `./downloads/${file}`);
}
