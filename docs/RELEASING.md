# DoIt 릴리스 운영 안내

릴리스 도구는 **로컬 후보 준비**까지만 합니다. 자동 커밋·태그·설치·업로드·게시를 하지 않으며 `site/appcast.xml`도 바꾸지 않습니다.

정식 appcast는 `https://prestige-kim.github.io/DoIt/appcast.xml`이며 `DoItDistributionEnabled=true`입니다. 1.0.0·1.0.1·1.0.2(13)가 공개됐습니다. 1.0.2는 ZIP을 먼저 게시·검증한 뒤 appcast에 추가했습니다. 다음 릴리스도 같은 순서를 따릅니다. macOS 14 이상을 지원하지만 Intel의 실제 사용은 아직 확인하지 못했습니다.

## 준비

- Xcode·Command Line Tools·XcodeGen과 Sparkle **2.10.1** 공식 배포 도구가 필요합니다. 프로젝트 의존성도 정확히 2.10.1입니다.
- 정식 appcast 주소는 `https://<owner>.github.io/<repo>/appcast.xml` 형식이어야 합니다. 주소·공개 키와 bool `DoItDistributionEnabled`를 `project.yml`에서 검토한 뒤 `xcodegen generate`로 기준 plist도 맞추고 검토·커밋합니다. 공백·미치환 값·자리표시자·로컬 주소·검증 구성은 허용하지 않습니다.
- 앱 서명은 각 개발자가 준비한 `DoIt Self Signing`, 번들 ID는 `com.personal.doit`입니다. 배포자의 인증서·개인 키를 공유하지 않습니다.
- EdDSA 키는 기존 로그인 키체인의 DoIt 전용 account를 사용합니다. 키를 새로 만들거나 내보내는 기능은 이 도구에 없습니다. 암호화 백업은 저장소 밖에 보관하고 분실하지 마세요. 개인 키를 인자·환경 변수·노트·로그·저장소에 넣지 않습니다.
- 실행은 깨끗한 **main**에서만 허용합니다. staged/unstaged 변경과 무시되지 않는 미추적 파일도 없어야 합니다. `build`·`dist` 같은 무시 항목은 작업 트리 변경으로 보지 않습니다.
- 노트는 미리 커밋한 파일 또는 저장소 밖의 명시한 파일 1개를 사용합니다. 실제 과목·과제·개인 주소·이메일·키를 넣지 않습니다. Git 이력으로 노트를 자동 생성하지 않습니다.

## 한국어 노트 양식

아래처럼 `.md` 또는 `.txt` 파일을 UTF-8로 저장합니다. 비어 있거나 32KiB를 넘는 노트, 개인 경로·이메일·토큰·키·피드 주소 등은 거부합니다. 파일명만 바꿔 비밀 파일을 노트로 지정하지 마세요.

```markdown
# 변경 사항
- 어떤 동작이 개선됐는지 간단히 적습니다.

# 확인한 사항
- 사용자가 알아야 할 동작과 지원 환경을 적습니다.

# 알려진 한계
- 아직 확인하지 못한 환경이 있다면 적습니다.
```

## 1. 읽기 전용 점검

```sh
scripts/release.sh 1.0.2 --notes <한국어-노트.md> --dry-run
```

작업 브랜치나 미설정 상태에서도 현재 버전·예정 빌드·산출물·차단 이유를 볼 수 있습니다. `--dry-run`은 파일·Git·키체인·네트워크를 바꾸지 않습니다. 차단 이유가 있으면 종료 코드 1입니다. 키 존재·코드 서명 인증서·실제 빌드 검증은 실제 실행에서 수행합니다.

기본 도구 위치는 SPM의 `build/SourcePackages/artifacts/sparkle/Sparkle`입니다. 별도 공식 배포 도구를 사용할 때는 `--sparkle-tools <Sparkle-2.10.1-폴더>`를 붙입니다. 이는 도구 위치 선택이며 보안 검사 생략 옵션이 아닙니다. 도구 옆 framework의 버전과 실제 도구 help를 확인합니다.

## 2. 로컬 릴리스 후보 준비

사용자 발행 승인과 실주소·키·깨끗한 main 준비가 끝난 경우에만 다음을 실행합니다. 다음 릴리스에서는 실제 공개 최신 버전보다 높은 버전을 지정합니다.

```sh
scripts/release.sh 1.0.2 --notes <한국어-노트.md>
```

버전은 숫자 세 부분의 엄격한 SemVer입니다. prerelease와 build metadata는 받지 않습니다. 낮은 버전은 거부하고 같은 마케팅 버전의 재빌드는 허용하지만 이미 게시한 ZIP·태그를 교체하지 않습니다. 첫 공개는 1.0.0(11), 이후 1.0.1(12), 1.0.2(13) 순서입니다.

새 빌드는 프로젝트·기존 appcast·로컬 릴리스 기록의 가장 큰 유효 번호보다 1 큽니다. 설치본·사용자 데이터에서 번호를 읽지 않습니다. 1.0.2의 빌드는 13이며, 그 뒤 번호는 실제 기록을 기준으로 다시 확인합니다. 부정확한 기록·중복 빌드·이름 충돌을 임의로 고치지 않습니다.

도구가 하는 일은 다음과 같습니다.

1. main·변경 상태·버전·노트·정식 구성·기록·도구를 검사하고 기존 서명 키의 공개 키가 앱 설정과 같은지 확인합니다.
2. `project.yml`의 버전·빌드 두 값만 바꿔 Release를 빌드합니다.
3. 번들 ID·버전·공개 키·정식 구성·arm64/x86_64·앱/중첩 서명을 검사하고 `package.sh`의 보호된 경로로 zip을 만듭니다. framework symlink·실행 권한은 ditto로 보존합니다.
4. 정확히 그 zip을 키체인의 기존 키로 서명합니다. Sparkle 검증 외에 앱 공개 키를 사용한 CryptoKit Ed25519 검증도 수행하고, zip 내부 앱을 재추출해 대조합니다.
5. 노트·후보 XML·manifest와 zip이 서로 일치할 때만 고유한 릴리스 폴더로 반영합니다.

산출물은 `dist/DoIt-<버전>-<빌드>/`에 있습니다.

- `DoIt-<버전>-<빌드>.zip`: 앱만 포함하는 최종 서명 대상.
- `release.manifest.json`: 원본 SHA·이전/새 버전·빌드·zip 크기/해시/공개 서명·다운로드 URL·최소 OS·노트/후보 해시. 원본 SHA는 **로컬 관리 정보**이며 공개 appcast·노트에는 넣지 않습니다. manifest를 공개 자료로 함께 올리지 마세요.
- `appcast-candidate.xml`: 기존 항목을 보존하고 새 빌드 정수·표시 버전·최소 macOS 14.0.0·한국어 제목/노트·zip URL/바이트 수/서명을 넣은 후보.
- `release-notes.md`: 명시한 한국어 노트의 복사본.

다운로드 URL의 릴리스 태그는 `v<버전>-<빌드>`, 자산명은 zip 이름과 같습니다. 소유자·저장소는 정식 appcast 주소와 같아야 합니다. 앱의 릴리스 노트 표시를 켜는 변경은 하지 않습니다.

성공 뒤에도 자동 커밋하지 않습니다. `project.yml`의 두 값 diff와 산출물, 원본 SHA·버전 변경 관계를 직접 검토한 뒤 별도 커밋 절차를 진행합니다.

## 3. 업로드 직전 재검증

```sh
scripts/release.sh --verify dist/DoIt-<버전>-<빌드>/release.manifest.json
```

로컬 원본 커밋의 프로젝트와 버전 두 값의 변경 해시, 현재 설정의 공개 키와 manifest·appcast·노트·zip의 이름/크기/해시/서명, 내부 앱의 버전·구성·중첩 서명을 다시 대조합니다. 입력·산출물을 수정하거나 키체인을 사용하지 않습니다. 실제 공개 주소가 존재한다는 확인은 이 명령에 포함되지 않습니다.

## 4. 실제 발행 — 반드시 zip부터

이번 도구는 이 단계를 수행하지 않습니다. 계정·저장소·공개 승인과 발행 담당자의 검토가 끝난 뒤 별도로 진행합니다.

1. 최신 manifest와 zip을 다시 검증하고 버전·빌드·해시·EdDSA 서명을 확인합니다.
2. 같은 소유자/저장소의 지정 릴리스 태그에 **정확히 그 zip을 먼저 업로드**합니다.
3. manifest의 다운로드 주소에서 실제 파일을 내려받아 이름·바이트 수·SHA256·앱 정보·EdDSA 서명을 다시 확인합니다. 새로 압축하거나 서명 뒤 내용을 바꾸지 않습니다.
4. 파일 확인이 끝난 뒤에만 `appcast-candidate.xml`을 `site/appcast.xml`에 반영하고 검토·공개합니다. 기존 항목이 유지되는지 다시 확인합니다.
5. 정식 주소에서의 앱 확인·다운로드·설치·재실행·데이터/권한·인증 창 횟수를 별도로 실측합니다.

업로드가 실패했거나 파일이 다르면 **appcast를 공개하지 않습니다**. appcast만 먼저 공개해 다운로드 실패를 만들지 않습니다. 이 도구에는 업로드 완료를 임의로 인정하거나 site를 자동 덮어쓰는 옵션이 없습니다.

## 실패·동시 실행·복구

- 실패하면 도구가 쓴 프로젝트 버전 원문이 그대로 남아 있는 경우에만 이전 원문으로 복구합니다. 도중 외부 편집이 있으면 덮어쓰지 않고 충돌로 알립니다. `git reset`·`git clean`으로 사용자 작업을 되돌리지 않습니다.
- 이번 실행의 staging만 정리하며 기존 `dist`·site·사용자 파일은 삭제하거나 덮어쓰지 않습니다. 정상 완료 전에 산출물 일부를 공개 폴더에 나눠 쓰지 않습니다.
- 같은 Git 저장소는 운영체제 lock으로 동시 실행을 막습니다. lock 파일은 inode 교체 경쟁을 피하려고 Git 내부에 유지하며 정상·실패·종료 시 열린 핸들을 닫아 lock을 해제합니다. dry-run은 lock 파일도 만들지 않습니다.
- 강제 종료·전원 장애는 자동 복구를 보장하지 않습니다. 남은 버전 diff·staging·기존 산출물을 확인하고 사용자가 정리한 뒤 다시 점검합니다. 서명 검증을 꺼서 복구하지 않습니다.
- 오류는 규칙·건수만 안내하며 개인 경로·키·민감한 노트 원문은 출력하지 않습니다. 자동 검사가 모든 비밀을 찾아낸다는 보장은 없습니다.

## 로컬 도구 검증과 실제 배포의 차이

정상/실패 경로는 별도 임시 Git 저장소와 가짜 주소·가짜 노트로 시험할 수 있습니다. 원본의 main·0.9.2(10)·설치본·공개 준비 gate 차단 정책을 바꾸지 않습니다. mock 빌드/서명 검증과 실제 앱 zip·키체인 서명·암호 검증 결과를 구분해 기록합니다. 임시 성공을 원격 업로드·공개·다른 맥 설치 성공으로 확대하지 않습니다.

## 현재 확인 범위

Sparkle 로컬 8→9 업데이트와 이 Mac의 정식 원격 1.0.0→1.0.1 업데이트에서 사용자 보고 추가 암호·허용 창은 0번이며 기존 내용·알림도 유지됐습니다. 설정 전체 항목과 다른 Mac의 설치·업데이트는 확인하지 못했습니다. 현재 공개 앱 릴리스는 1.0.2(13)이며, 이 버전으로의 실제 앱 업데이트는 별도 실측이 필요합니다. 번들 gate는 defaults·환경·실행 인자로 활성화할 수 없으며 학생 UI 스위치가 아닙니다.

랜딩 저장소/Issues 주소·다운로드·Pages는 공개됐습니다. Apple 배경/메뉴바 자산의 공개 사용 조건 또는 대체 자산, 최종 환경별 QA, NotchNotification 고지는 미확인 과제입니다. 출처 고지는 공개 재배포 권리 확인을 뜻하지 않습니다.

## Windows 릴리스

Windows 버전은 Mac과 **별도 번호**를 씁니다. 첫 공개는 1.0.0(빌드 1)이며 Release 태그는 `windows-v<버전>-<빌드>`, 설치 파일은 `DoIt-Windows-<버전>-<빌드>-{x64,arm64}-Setup.exe`입니다. 위의 Mac 도구(`release.sh`)·appcast는 Windows에 쓰지 않습니다. Windows 앱에는 자동 업데이트가 없고, 사용자가 새 설치 파일을 받아 실행하면 데이터를 유지한 채 덮어씁니다.

### 버전 정책

- 버전은 숫자 세 부분 `x.y.z`, 빌드는 1~65535 정수입니다. Mac 버전과 맞출 필요가 없습니다.
- 한 번 게시한 태그·파일 이름·번호는 **다시 쓰지 않습니다**. 이미 올린 EXE를 같은 이름으로 교체하지 않습니다.
- 후보 검증이나 업로드가 실패해 다시 빌드하면 버전이 같아도 **빌드 번호를 1 올립니다**(예: 1.0.0-1 실패 → 1.0.0-2). 기능이 바뀌면 버전을 올리고 빌드 번호는 그대로 계속 늘립니다.

### 서명과 첫 실행 경고

설치 파일과 앱은 **코드 서명이 없습니다**. 그래서 브라우저가 다운로드를 경고하거나 Windows SmartScreen이 "Windows의 PC 보호" 창을 띄울 수 있습니다. 랜딩 설치 안내에 "유지" → "추가 정보" → "실행" 순서와 `Get-FileHash`로 SHA-256을 확인하는 방법을 적어 둡니다. 서명이 없다는 사실을 숨기거나 경고를 끄는 방법을 안내하지 않습니다. `package_windows.py`는 설치 파일에 서명 정보가 있으면 오히려 거부합니다(무서명 NSIS 런처만 허용).

### 1. 준비물

- 공개 저장소 `prestige-kim/DoIt`에 push·Release·Actions 실행을 할 수 있는 `gh` 로그인(Mac 쪽).
- 실기기 검증용 **Windows 11 PC**(가능하면 x64와 Arm64 각각). 이 PC에는 브라우저와 GitHub 로그인만 있으면 됩니다. Arm64 기기가 없으면 x64만 공개합니다(아래 `--only`).
- 설치 파일은 GitHub의 Windows 서버에서 `.github/workflows/windows-candidate.yml`이 만듭니다. Windows App SDK 알림 매니페스트 병합에 Windows의 `mt.exe`가 필요해서 Mac에서는 만들 수 없습니다.

### 2. 공개 소스 내보내기·push

workflow는 공개 저장소의 소스로 빌드하므로 먼저 공개 소스를 맞춥니다.

```sh
scripts/export-public.sh <공개용-폴더>
```

공개용 폴더에서 바뀐 파일을 검토하고 **고른 파일만** 커밋합니다. 커밋 메시지는 영어 한 줄이며 AI 공동 작성자 트레일러를 넣지 않습니다. 원본 저장소의 Git 이력은 push하지 않습니다. Pages는 수동 실행이라 push만으로 소개 페이지가 바뀌지는 않습니다.

### 3. 후보 만들기 (GitHub Actions → 초안 릴리스)

```sh
gh workflow run windows-candidate.yml --repo prestige-kim/DoIt --ref main -f version=1.0.0 -f build=1
gh run watch --repo prestige-kim/DoIt $(gh run list --repo prestige-kim/DoIt --workflow windows-candidate.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

workflow는 C# 테스트 → x64·Arm64 설치 파일 생성(PE 아키텍처·무서명 확인) → **초안(draft) 릴리스** `windows-v<버전>-<빌드>`에 EXE 2개, `SHA256SUMS.txt`, `manifest.json`을 올립니다. 같은 태그가 이미 있으면 멈춥니다. 초안은 저장소 관리자만 볼 수 있고, 게시하면 같은 파일이 그대로 공개됩니다.

`manifest.json`은 Mac으로 받아 둡니다. 다운로드 설정 도구가 읽습니다.

```sh
gh release download windows-v1.0.0-1 --repo prestige-kim/DoIt --pattern manifest.json --dir <후보-폴더>
```

(대안) Windows PC에 .NET 10 SDK·Python 3·NSIS를 설치해 `python windows\packaging\package_windows.py --version 1.0.0 --build 1 --output <후보-폴더>`로 직접 만들 수도 있습니다. 이때는 `preview/` 검증용 랜딩 사본도 함께 생기며, 5단계의 Release는 `gh release create`로 직접 만듭니다.

### 4. 실기기 검증

검증 PC 브라우저에서 GitHub에 로그인한 뒤 `https://github.com/prestige-kim/DoIt/releases`의 초안에서 설치 파일을 눌러 받습니다. PowerShell `Get-FileHash <파일> -Algorithm SHA256`을 `SHA256SUMS.txt`와 비교하고, 설치·사용권 동의·첫 실행 경고·할 일 저장·알림·재실행·덮어쓰기 설치·제거를 확인합니다. 실패하면 원인을 고쳐 2단계(내보내기·push)를 다시 하고 **빌드 번호를 올려** 3단계를 다시 실행합니다. 실패한 초안은 게시하지 않고 삭제합니다(`gh release delete windows-v1.0.0-1 --repo prestige-kim/DoIt`). 검증하지 못한 아키텍처는 공개하지 않습니다.

### 5. 초안 게시

검증을 마친 초안을 그대로 게시합니다. 게시하면 workflow가 빌드한 공개 커밋에 태그가 생깁니다.

```sh
gh release delete-asset windows-v1.0.0-1 manifest.json --repo prestige-kim/DoIt --yes
gh release edit windows-v1.0.0-1 --repo prestige-kim/DoIt --draft=false
```

x64만 공개할 때는 게시 전에 arm64 EXE를 지우고(`gh release delete-asset ... DoIt-Windows-1.0.0-1-arm64-Setup.exe`), `SHA256SUMS.txt`를 x64 한 줄만 남긴 사본으로 바꿉니다(`gh release upload ... SHA256SUMS.txt --clobber`). 노트에는 무서명·SmartScreen 경고·지원 환경이 들어 있고 AI 트레일러·개인 정보는 없습니다.

### 6. 비인증 재다운로드 대조

로그인 정보 없이(`gh`가 아닌 `curl`) 공개 주소에서 다시 받아, 올린 파일과 같은지 크기·해시로 확인합니다.

```sh
mkdir <재다운로드-폴더> && cd <재다운로드-폴더>
for f in DoIt-Windows-1.0.0-1-x64-Setup.exe DoIt-Windows-1.0.0-1-arm64-Setup.exe SHA256SUMS.txt; do
  curl -fL -o "$f" "https://github.com/prestige-kim/DoIt/releases/download/windows-v1.0.0-1/$f"
done
shasum -a 256 -c SHA256SUMS.txt
```

이어서 다운로드 설정 도구로 manifest와 대조합니다(아래 7단계의 `--verify-file`). 어느 하나라도 다르면 다운로드 설정을 켜지 않습니다.

### 7. 다운로드 설정 켜기

`scripts/windows_release_config.py`가 manifest를 읽어 `site/windows-download.js`의 `WINDOWS_RELEASE` 한 줄만 공개 값으로 바꿉니다. 기본은 **미리보기**(바뀔 줄만 출력, 파일 그대로)이고 `--write`일 때만 씁니다.

```sh
# 미리보기 + 재다운로드 파일 대조
python3 scripts/windows_release_config.py <manifest.json> \
  --verify-file <재다운로드-폴더>/DoIt-Windows-1.0.0-1-x64-Setup.exe <재다운로드-폴더>/DoIt-Windows-1.0.0-1-arm64-Setup.exe
# 확인 후 쓰기
python3 scripts/windows_release_config.py <manifest.json> --verify-file <같은 파일들> --write
# Arm64를 검증하지 못했을 때
python3 scripts/windows_release_config.py <manifest.json> --only x64 --verify-file <x64 파일> --write
```

도구는 버전 `x.y.z`, 빌드 1~65535, 자산 파일명 형식, SHA-256 64자리 16진수, 아키텍처 이름을 검사하고, URL을 `site/config.js`의 owner·repository로 만든 GitHub Releases 주소(`verifiedWindowsDownload`가 기대하는 주소)와 똑같이 맞춥니다. `node`가 있으면 바뀐 내용의 임시 사본에서 `verifiedWindowsDownload()`를 실제로 실행해 결과가 기대와 같은지 확인하고, 없으면 그 검사만 건너뜁니다. 하나라도 실패하거나 `WINDOWS_RELEASE` 한 줄 형식을 찾지 못하면 이유를 출력하고 종료 코드 1로 끝나며 파일은 바뀌지 않습니다.

`git diff site/windows-download.js`로 한 줄만 바뀐 것을 확인하고 원본 저장소에 커밋합니다.

### 8. README·공개 반영·Pages

1. 공개 README에 Windows 다운로드 안내(랜딩 Windows 탭 링크, 지원 환경, 무서명 경고, SHA-256 확인)를 추가하고 커밋합니다.
2. 2단계처럼 다시 내보내기 → 고른 파일만 커밋·push합니다.
3. Pages는 자동으로 돌지 않으므로 수동 실행합니다.

```sh
gh workflow run pages.yml --repo prestige-kim/DoIt --ref main
gh run list --repo prestige-kim/DoIt --workflow pages.yml --limit 1
```

### 9. 공개 페이지 재확인

`https://prestige-kim.github.io/DoIt/#windows-install`을 새로 고침(캐시를 피하려면 강력 새로 고침)해 Windows 탭에 켠 아키텍처의 버튼과 SHA-256만 보이는지 확인합니다. 버튼으로 다시 받은 파일의 해시가 페이지·`SHA256SUMS.txt`와 같은지 확인합니다. Mac 탭의 다운로드·appcast가 그대로인지도 봅니다.

### 10. Contributors 확인

```sh
gh api repos/prestige-kim/DoIt/contributors --jq '.[].login'
```

공개 저장소 Contributors에 AI 계정이 없는지 확인합니다. 있으면 해당 커밋을 찾아 원인을 기록하고 다음 공개 절차에서 바로잡습니다.

### 실패했을 때

- Release 업로드 전 실패: 공개 페이지는 그대로이므로 고친 뒤 빌드 번호를 올려 다시 합니다.
- Release 후 재다운로드 불일치: `WINDOWS_RELEASE`를 켜지 않습니다. 새 빌드 번호로 다시 올리고 잘못된 Release는 내용을 바꾸지 말고 초안·삭제 여부를 따로 판단합니다.
- 공개 후 문제가 생기면 `WINDOWS_RELEASE`를 `releasePublished: false`로 되돌린 내용을 내보내기·push·Pages 실행으로 먼저 반영해 버튼을 끕니다.
