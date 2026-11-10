# DoIt 스크립트 공통 (T-010). run.sh·install.sh·package.sh가 source 한다.

SIGN_IDENTITY="DoIt Self Signing"
INSTALLED_APP="/Applications/DoIt.app"

# 서명 인증서가 로그인 키체인에 있는지 확인. 없으면 알아보기 쉬운 안내 후 종료 (D-017)
require_signing_identity() {
  if ! /usr/bin/security find-identity -p codesigning | grep -q "\"${SIGN_IDENTITY}\""; then
    echo "서명 인증서 '${SIGN_IDENTITY}'가 로그인 키체인에 없어요."
    echo "- 백업해 둔 .p12 파일을 '키체인 접근' 앱으로 가져온 뒤 다시 실행하세요."
    echo "- 인증서 없이 잠깐 시험만 하려면: xcodebuild ... CODE_SIGN_IDENTITY=-  (임시 서명, 설치·배포에는 쓰지 않음)"
    exit 1
  fi
}

# 실행 중인 DoIt을 모두 종료 (Debug 빌드든 설치본이든 번들 ID가 같아 동시에 못 뜬다). 최대 약 3초 기다림
quit_running_doit() {
  if pgrep -x DoIt >/dev/null; then
    echo "실행 중인 DoIt을 종료해요: $(pgrep -lx DoIt | head -3 | tr '\n' ' ')"
    # 기존 run.sh와 같은 방식(SIGTERM). Apple 이벤트(osascript quit)는 '자동화' 권한 창이 생길 수 있어 쓰지 않는다
    pkill -x DoIt || true
    for _ in {1..30}; do pgrep -x DoIt >/dev/null || return 0; sleep 0.1; done
    echo "DoIt이 종료되지 않았어요. 메뉴바에서 'DoIt 종료'를 누른 뒤 다시 실행하세요."
    exit 1
  fi
}

# Info.plist의 버전 "0.9.0 (2)"
app_version() {
  local plist="$1/Contents/Info.plist"
  echo "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist"))"
}

# T-012c: 검증한 앱을 기존 산출물 덮어쓰기 없이 포장한다. 서명·설정 보호는 항상 적용.
package_app() (
  set -euo pipefail
  local app="$1" output="$2" stage
  [[ -d "$app" && ! -L "$app" && "$app" == *.app ]] || { echo '포장 차단: 일반 앱 번들이 필요해요.'; exit 1; }
  codesign --verify --strict "$app"
  /usr/bin/python3 scripts/lib/update_config.py package "$app/Contents/Info.plist"
  [[ ! -e "$output" && ! -L "$output" ]] || { echo '포장 차단: 기존 산출물은 덮어쓰지 않아요.'; exit 1; }
  mkdir -p "$(dirname "$output")"
  stage=$(mktemp -d "$(dirname "$output")/.doit-package-XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  ditto -c -k --keepParent "$app" "$stage/archive.zip"
  # 같은 파일시스템에서 link 생성은 이름이 있으면 실패한다. 검사 이후 충돌도 덮어쓰지 않는다.
  ln "$stage/archive.zip" "$output"
)
