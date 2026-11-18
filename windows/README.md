# DoIt Windows 개발 검증

Windows 11용 DoIt 트레이 앱입니다. 시계 옆 DoIt 아이콘을 누르면 할 일 목록이 열리고, 같은 창에서 월간 달력을 보며, 전체 편집기와 설정은 별도 창으로 엽니다. 개인 할 일 추가·완료·삭제, 읽기 전용 LMS 과제, 기록 정리, 오늘 마감 건수 알림이 구현돼 있습니다.

**입력한 할 일과 설정은 실제로 저장됩니다** (`%LOCALAPPDATA%\DoIt\`). 검증할 때는 실제 할 일 대신 시험용 문구를 쓰고, LMS 피드 주소는 설정 창에만 입력하세요. 아직 Windows 실기기에서 빌드·실행한 기록은 없습니다.

## Windows 11에서 실행

1. Windows PC의 시스템 종류에 맞는 **.NET 10 SDK**(x64 또는 Arm64)를 설치합니다. [Microsoft 설치 안내](https://learn.microsoft.com/ko-kr/dotnet/core/install/windows)
2. 소스 ZIP을 풀고 `windows` 폴더가 보이는 위치에서 PowerShell을 엽니다. 저장소에서 실행하는 경우 저장소 루트에서 시작합니다.
3. 아래 명령을 순서대로 실행합니다. 자동 테스트는 통과·실패 건수를 출력합니다.

   ```powershell
   dotnet --info
   dotnet run --project windows/DoIt.Core.Tests/DoIt.Core.Tests.csproj
   dotnet build windows/DoIt.Windows/DoIt.Windows.csproj -r win-x64
   dotnet run --project windows/DoIt.Windows/DoIt.Windows.csproj -r win-x64
   ```

   Arm64 PC에서는 `win-x64` 대신 `win-arm64`를 씁니다. 런타임(`-r`)을 지정해야 알림에 필요한 Windows App SDK가 앱과 함께 들어갑니다. 개발 실행본에서는 로그인 시 시작과 앱 종료 중 알림 예약이 꺼져 있습니다. 이 두 기능은 설치본에서만 동작합니다.

4. 시계 근처의 DoIt 아이콘을 누릅니다. 아이콘이 보이지 않으면 `^` 숨겨진 아이콘 메뉴를 엽니다. 항상 보이게 하려면 설정 → 개인 설정 → 작업 표시줄 → 기타 시스템 트레이 아이콘에서 DoIt을 켭니다. 테스트를 마치면 DoIt 아이콘을 우클릭하고 `종료`를 누릅니다.

## 화면에서 확인할 항목

- 일반 트레이와 `^` 메뉴에서 각각 아이콘을 눌러 패널이 열리고 다시 누르면 닫힙니다. 바탕 화면이나 다른 앱을 클릭하면 패널이 닫히고 원래 클릭도 전달됩니다.
- 목록에서 `달력`을 누르면 같은 창이 위로 커지고 `목록`으로 돌아오면 줄어듭니다. 다른 달과 날짜를 고르고 패널을 닫았다 다시 열면 그대로 보입니다. 목록에서 `달력`을 다시 누르면 이번 달·오늘로 돌아옵니다.
- 화면 배율이 다른 모니터와 작은 화면에서 창이 작업 표시줄을 제외한 영역 안에 들어옵니다. 달력과 스크롤을 조작할 수 있습니다.
- `Win+B`와 방향키로 트레이 아이콘에 이동해 Enter 또는 Space로 엽니다. Tab·Shift+Tab으로 패널을 탐색하고 Esc로 닫습니다. 입력 칸에서 Microsoft 한국어 IME로 `할 일`을 조합합니다. 조합·날짜 선택 중 마우스를 밖으로 움직여도 패널이 유지됩니다.
- 설정 창을 열고 최소화하거나 뒤로 보낸 뒤 다시 열면 같은 창이 앞으로 옵니다. 설정을 닫은 뒤에도 트레이 아이콘을 쓸 수 있습니다.

Windows 버전과 시스템 종류, 화면 해상도·배율, 실패한 동작을 함께 남겨 주세요.

## Mac에서 개발 검증

Mac의 .NET 10 SDK로는 C# 상태·배치 테스트를 실행하고 WPF 교차 빌드를 시도할 수 있습니다. 트레이·창·한글 입력 확인에는 Windows 데스크톱이 필요합니다. [교차 빌드 설정](https://learn.microsoft.com/ko-kr/dotnet/core/tools/sdk-errors/netsdk1100)

```sh
dotnet run --project windows/DoIt.Core.Tests/DoIt.Core.Tests.csproj
dotnet build windows/DoIt.Windows/DoIt.Windows.csproj -p:EnableWindowsTargeting=true
```

## Windows에서 최종 설치 후보 만들기

공개 저장소에서는 GitHub Actions의 `windows-candidate.yml`(수동 실행)이 Windows 서버에서 설치 파일을 만들어 초안 릴리스에 올립니다. 이때는 Windows PC에서 브라우저로 내려받기만 하면 됩니다. 아래는 Windows PC에서 직접 만드는 방법입니다.

Windows 11 빌드 PC에 .NET 10 SDK, Python 3, NSIS 3.13을 설치합니다. Git을 쓰는 경우 저장소 루트에서 실행합니다. 소스 ZIP을 받은 경우 ZIP을 풀고 `windows`가 보이는 폴더에서 실행하며, 첫 명령 끝에 `--source-zip .\DoIt-Windows-candidate-source.zip`을 붙입니다. ZIP 원본은 압축을 푼 폴더에도 복사해 둡니다. 소스 ZIP은 Mac 등에서 `git archive --format=zip --output=DoIt-Windows-candidate-source.zip HEAD windows/ site/ LICENSE`로 만듭니다(`LICENSE`는 설치 동의 화면에 들어갑니다). `makensis`가 PATH에 없으면 `--makensis`에 전체 경로를 지정합니다.

```powershell
py -3 windows/packaging/package_windows.py --version 1.0.0 --build 1 --output dist/windows-candidate
py -3 -m http.server 8765 --bind 127.0.0.1 --directory dist/windows-candidate/preview
```

브라우저에서 `http://127.0.0.1:8765/`를 열고 Windows 탭에서 시스템 종류에 맞는 후보를 다운로드합니다. `downloads/SHA256SUMS.txt`와 PowerShell의 `Get-FileHash -Algorithm SHA256` 결과를 대조한 뒤 설치합니다. 다른 PC에서 점검하려면 검증용 `preview` 폴더를 옮겨 그 PC의 localhost에서 열 수 있습니다. 공개 페이지에는 후보 설정을 복사하지 않습니다.
