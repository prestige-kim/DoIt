#!/bin/zsh
# 일반 Release 포장. 미설정·검증 앱은 차단하고 기존 zip은 덮어쓰지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh

if [[ $# -eq 0 ]]; then
  require_signing_identity
  xcodegen generate
  xcodebuild -project DoIt.xcodeproj -scheme DoIt -configuration Release -derivedDataPath build build -quiet
  built="build/Build/Products/Release/DoIt.app"
  short=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$built/Contents/Info.plist")
  build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$built/Contents/Info.plist")
  output="dist/DoIt-${short}-${build}.zip"
elif [[ $# -eq 4 && "$1" == --app && "$3" == --output ]]; then
  # 릴리스 도구의 동일 빌드 재사용 경로. 서명·배포 구성 검사는 생략하지 않는다.
  built="$2"
  output="$4"
else
  echo '사용법: scripts/package.sh [--app <Release 앱> --output <새 zip>]'
  exit 1
fi
package_app "$built" "$output"
echo "만듦: $output"
