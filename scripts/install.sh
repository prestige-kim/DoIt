#!/bin/zsh
# DoIt 설치 (T-010): Release 빌드(자체 서명) → 실행 중인 DoIt 종료 → /Applications/DoIt.app 교체 → 실행
# 개발용 Debug 빌드(scripts/run.sh)와 번들 ID가 같아 동시에 뜰 수 없으므로, 실행 중인 쪽을 먼저 종료한다.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh

require_signing_identity
xcodegen generate
xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration Release -derivedDataPath build build -quiet
built="build/Build/Products/Release/DoIt.app"
codesign --verify --strict "$built"

quit_running_doit
# ditto: 폴더째 복사(확장 속성·서명 유지). 이전 설치본은 지우고 새로 놓는다
rm -rf "$INSTALLED_APP"
ditto "$built" "$INSTALLED_APP"
# 교체 직후에는 macOS가 새 앱을 아직 등록하지 못해 open이 실패할 수 있다 → 잠깐 기다리며 최대 5번 시도
for i in {1..5}; do
  if err=$(open "$INSTALLED_APP" 2>&1); then break; fi
  echo "실행 재시도 ${i}/5: ${err}"
  [[ $i == 5 ]] && { echo "실행하지 못했어요. Finder에서 $INSTALLED_APP 을 직접 열어 주세요."; exit 1; }
  sleep 1
done
echo "DoIt $(app_version "$INSTALLED_APP") 설치·실행됨: $INSTALLED_APP"
echo "(개발용 빌드로 바꾸려면 scripts/run.sh — 그때 설치본은 종료돼요)"
