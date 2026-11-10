#!/bin/zsh
# DoIt 단위 테스트 (T-010). 테스트는 Debug DoIt을 호스트로 띄우는데, 설치본이 실행 중이면
# 중복 실행 방지(LSMultipleInstancesProhibited) 때문에 macOS가 띄우지 않는다 ("Could not launch DoItTests").
# → 실행 중인 DoIt을 먼저 끄고 테스트한 뒤, 설치본이 있으면 다시 켠다.
# 사용법: scripts/test.sh [xcodebuild에 더 넘길 인자...]   예) scripts/test.sh -only-testing:DoItTests/LoginItemTests
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh

require_signing_identity
was_running=0
pgrep -x DoIt >/dev/null && was_running=1
quit_running_doit
xcodegen generate >/dev/null
result=0
xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration Debug -derivedDataPath build test "$@" 2>&1 \
  | grep -aE "^/.*(error|warning):|failed \(|Executed [0-9]+ tests, |TEST (SUCCEEDED|FAILED)|Could not launch" | awk '!seen[$0]++' | tail -4 || true
result=${pipestatus[1]}
if [[ $was_running == 1 && -d "$INSTALLED_APP" ]]; then
  open "$INSTALLED_APP" && echo "설치본 DoIt을 다시 켰어요."
fi
exit $result
