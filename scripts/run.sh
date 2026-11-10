#!/bin/zsh
# DoIt 개발용(Debug) 빌드 후 실행. 실행 중인 DoIt(설치본 포함)이 있으면 종료하고 다시 실행한다.
# 설치본(/Applications/DoIt.app)과 번들 ID가 같아 둘이 동시에 뜰 수 없다 (T-010).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh

require_signing_identity
xcodegen generate
xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration Debug -derivedDataPath build build -quiet

quit_running_doit
open build/Build/Products/Debug/DoIt.app
echo "개발용 DoIt $(app_version build/Build/Products/Debug/DoIt.app) 실행됨. 메뉴바의 DoIt 아이콘을 누르세요."
echo "(설치본으로 돌아가려면 scripts/install.sh 또는 Finder에서 /Applications/DoIt.app 실행)"
