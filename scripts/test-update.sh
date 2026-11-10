#!/bin/zsh
# 로컬 업데이트 시험만. 산출물은 /private/tmp, 서버는 127.0.0.1:8765.
# prepare <공식 Sparkle 배포 도구 폴더> → 임시 작업 폴더 출력
# fixture <작업 폴더> → 사용자 데이터 없는 시험 앱 생성
# feed <작업 폴더> <good|bad-signature|tampered|different-code|fixture-good|fixture-bad-signature|fixture-tampered|fixture-different-code>
# serve <작업 폴더> → 전경 서버. Ctrl-C로 이 서버만 종료
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
mode="${1:-help}"
if [[ "$mode" == prepare ]]; then
  tools="${2:?공식 Sparkle 배포 도구 폴더가 필요해요}"
  [[ -x "$tools/bin/sign_update" ]] || { echo '공식 sign_update 도구가 없어요.'; exit 1; }
  require_signing_identity
  work=$(mktemp -d /private/tmp/doit-update-validation-XXXXXX)
  chmod 700 "$work"
  echo "$work" > "$work/.doit-validation-root"
  xcodegen generate >/dev/null
  for version in 8 9; do
    xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration UpdateValidation \
      -derivedDataPath "$work/build" CURRENT_PROJECT_VERSION="$version" build > "$work/build-$version.log" 2>&1
    app="$work/build/Build/Products/UpdateValidation/DoIt.app"
    /usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: p = plistlib.load(f)
assert p.get('DoItUpdateValidation') is True
assert p['SUFeedURL'] == 'http://127.0.0.1:8765/appcast.xml'
PY
    codesign --verify --strict "$app"
    ditto "$app" "$work/DoIt-$version.app"
  done
  /usr/bin/python3 scripts/lib/update_validation.py prepare "$work" "$tools"
  echo "로컬 검증 준비 완료: $work"
  echo '아직 앱을 실행하거나 설치본을 바꾸지 않았어요. 먼저 fixture로 사용자 데이터 없는 시험을 진행하세요.'
elif [[ "$mode" == fixture ]]; then
  /usr/bin/python3 scripts/lib/update_validation.py fixture "${2:?작업 폴더}" "${3:?공식 Sparkle 배포 도구 폴더}"
elif [[ "$mode" == feed || "$mode" == serve ]]; then
  /usr/bin/python3 scripts/lib/update_validation.py "$mode" "${2:?작업 폴더}" "${3:-}"
else
  echo '사용법: scripts/test-update.sh prepare <공식 Sparkle 도구 폴더>'
  echo '        scripts/test-update.sh fixture <임시 작업 폴더> <공식 Sparkle 도구 폴더>'
  echo '        scripts/test-update.sh feed <임시 작업 폴더> <시험 종류>'
  echo '        scripts/test-update.sh serve <임시 작업 폴더>  (종료: Ctrl-C)'
  exit 1
fi
