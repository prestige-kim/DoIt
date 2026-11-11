// 공개 주소 확정·업로드 확인 후 이 파일 한 곳에서만 배포 정보를 바꿉니다.
export const SITE_CONFIG = Object.freeze({
  releasePublished: true,
  version: '1.0.2',
  build: 13,
  owner: 'prestige-kim',
  repository: 'DoIt',
  downloadURL: 'https://github.com/prestige-kim/DoIt/releases/download/v1.0.2-13/DoIt-1.0.2-13.zip',
  minimumMacOS: '14',
  support: 'Apple Silicon 실사용 확인 · Intel 실사용 확인 중',
  issuesURL: 'https://github.com/prestige-kim/DoIt/issues',
});

export function verifiedDownload(config) {
  if (config.releasePublished !== true || typeof config.version !== 'string' ||
      !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(config.version) ||
      !Number.isSafeInteger(config.build) || config.build < 1 ||
      typeof config.owner !== 'string' || !/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/.test(config.owner) ||
      typeof config.repository !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(config.repository) ||
      /example|placeholder|your-owner|your-repo|demo/i.test(config.owner + '/' + config.repository) ||
      typeof config.downloadURL !== 'string' || /\s|[<>{}]/.test(config.downloadURL)) return null;
  const expected = `https://github.com/${config.owner}/${config.repository}/releases/download/v${config.version}-${config.build}/DoIt-${config.version}-${config.build}.zip`;
  try {
    const url = new URL(config.downloadURL);
    if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.port || url.username ||
        url.password || url.search || url.hash || url.href !== expected) return null;
    return expected;
  } catch { return null; }
}
