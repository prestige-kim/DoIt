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

# xcodegen 등 중간 단계가 실패해도 원래 실행 중이던 설치본은 다시 켠다.
# 복원 명령의 결과가 테스트의 원래 실패 코드를 덮지 않게 한다.
restore_installed_app() {
  local original_result=$?
  trap - EXIT
  if [[ $was_running == 1 && -d "$INSTALLED_APP" ]]; then
    if open "$INSTALLED_APP"; then
      echo "설치본 DoIt을 다시 켰어요."
    else
      echo "설치본 DoIt을 다시 켜지 못했어요. 직접 실행해 주세요." >&2
      if [[ $original_result == 0 ]]; then original_result=1; fi
    fi
  fi
  exit "$original_result"
}
trap restore_installed_app EXIT

quit_running_doit
xcodegen generate >/dev/null
# grep은 출력이 없으면 1을 반환하므로 파이프라인 전체 대신 xcodebuild 상태를 쓴다.
# || true 같은 다른 명령이 pipestatus를 바꾸기 전에 즉시 보존한다.
set +e
xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration Debug -derivedDataPath build test "$@" 2>&1 \
  | grep -aE "^/.*(error|warning):|failed \(|Executed [0-9]+ tests, |TEST (SUCCEEDED|FAILED)|Could not launch" | awk '!seen[$0]++' | tail -4
build_pipeline_status=("${pipestatus[@]}")
set -e
exit "${build_pipeline_status[1]}"
