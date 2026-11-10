# DoIt 아키텍처 v0.13

> "어떻게 만드는가"의 기준. 구현 중 이 문서와 다르게 해야 할 이유가 생기면 임의로 바꾸지 말고 문서 관리 담당자에게 제안한다.
> 개정: 2026-11-10, 랜딩 최종 방향 반영·T-012e-2 주소/공개 전 차단 구현·검증 완료.

## 1. 기술 스택
- Swift (언어 모드 **Swift 5**, UI 코드는 `@MainActor`), SwiftUI + AppKit
- 최소 지원: macOS 14.0
- 프로젝트 생성: **XcodeGen** (`project.yml`이 원본, `*.xcodeproj`는 커밋하지 않음)
- 빌드: `xcodebuild` (터미널만으로 빌드·검증 가능해야 함)
- Dock 아이콘 없음: `LSUIElement = YES`
- 서명: Debug·Release 모두 **DoIt Self Signing** 자체 서명 인증서 고정, 번들 ID `com.personal.doit` 유지(D-017). 인증서·개인 키는 저장소 밖에 보관한다.
- 외부 패키지: 기본 금지. 예외 D-019의 Sparkle 2 하나만 SPM 정확한 버전으로 고정해 허용한다.

## 2. 폴더 구조 (목표)
```
DoIt/
├─ project.yml
├─ THIRD_PARTY_NOTICES.md      # 외부 코드 참고·차용 시 출처
├─ scripts/
│  └─ run.sh                   # 빌드 후 앱 실행
├─ DoIt/
│  ├─ App/                     # DoItApp, AppDelegate
│  ├─ StatusBar/               # StatusItemController (메뉴바 아이콘·메뉴)
│  ├─ Notch/                   # NotchGeometry, NotchPanel, NotchWindowController, NotchShape, NotchViewModel
│  ├─ Features/TodoList/       # 목록·행·빠른 추가 SwiftUI 뷰
│  ├─ Data/                    # Todo, TodoStore
│  ├─ Notifications/           # ReminderScheduler (T-005)
│  ├─ Editor/                  # WKWebView 전체 편집기 (T-006)
│  ├─ Lms/                     # IcsParser, LmsSyncService, LmsStore, 피드 주소 파일 저장소 (T-007, T-013)
│  ├─ Settings/                # 설정 창 (T-007)
│  └─ Resources/               # Info.plist, Assets
├─ DoItTests/
└─ docs/
   └─ PRD.md · ARCHITECTURE.md · DESIGN.md
```

## 3. 핵심 컴포넌트

### 3.1 NotchGeometry — 어디에 그릴지
- 대상 화면: `NSScreen.screens.first` (메뉴바가 있는 주 디스플레이). **`NSScreen.main` 사용 금지** (활성 창이 있는 화면을 뜻함)
- 실제 노치 판별: `screen.safeAreaInsets.top > 0`
  - 노치 높이 = `safeAreaInsets.top`
  - 노치 x 범위 = `auxiliaryTopLeftArea.maxX` ~ `auxiliaryTopRightArea.minX`
- 노치가 없으면 가상 노치:
  - 높이 = 메뉴바 높이 (`screen.frame.maxY - screen.visibleFrame.maxY`, 0이면 `NSStatusBar.system.thickness`)
  - 너비 = 기본 180pt, 상단 중앙 정렬
- `NSApplication.didChangeScreenParametersNotification` 수신 시 다시 계산
- 디버그용 "가상 노치 강제" 옵션 (외부 모니터 없이 테스트)

### 3.0 디자인 구현 원칙 (T-011)
- 화면 모양·색·배치의 기준은 `docs/DESIGN.md`
- 색은 Asset Catalog의 **밝은/어두운 쌍 Color Set**으로 등록하고 코드에서는 역할 이름(`PanelBackground`, `TodoAccent`, `LmsAccent`, `OverdueAccent` 등)으로만 쓴다. 코드에 hex 값을 직접 쓰지 않는다
- 밝은·어두운 전환은 시스템 설정을 따르며, 노치 패널에 강제로 `.dark`를 걸지 않는다
- **접힌 상태(실제·가상 노치 자리)는 항상 검은색**을 유지한다(가상 노치가 빈 공간을 메우는 역할). 펼칠 때 카드 색으로 바뀐다
- 그림자는 펼친 상태에서만(§5-3). 그림자가 잘리지 않도록 창 프레임에 여백(12pt)을 둔다. hover 판정은 **여백 포함 창 기준으로 확정**(T-008에서 카드 모양 기준을 시험했으나 사용자 확인 후 되돌림, 대신 이탈 0.1초 유예 §3.3)
- 펼친 패널은 노치 옆 메뉴바 띠까지 덮고 그 띠에 머리줄을 둔다(T-011, DESIGN.md)

### 3.2 NotchPanel — 무엇에 그릴지
- `NSPanel` 서브클래스
  - `styleMask: [.borderless, .nonactivatingPanel]`
  - 메뉴바보다 높은 window level (예: `.mainMenu + 3`). 실험해서 확정하고 보고서에 기록
  - `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  - `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`
  - `canBecomeKey → true` (패널 안 텍스트 입력용), `canBecomeMain → false`
- 접혔을 때는 패널 프레임을 **노치 영역 크기로 줄여**, 메뉴바의 다른 클릭을 방해하지 않는다
- 펼칠 때는 프레임을 펼친 크기로 먼저 키운 뒤 SwiftUI 애니메이션, 접힘 애니메이션이 끝나면 다시 줄인다
- 펼친 크기: 너비 약 420pt, 높이는 내용에 맞추되 최대 약 360pt
- **프레임 변경 규칙 (T-001c 교훈)**: SwiftUI 애니메이션 완료 콜백이나 레이아웃 도중에 `setFrame`을 직접 부르지 않는다. 반드시 `DispatchQueue.main.async`로 현재 레이아웃이 끝난 다음 차례에 1번 실행한다. (어기면 창이 엉뚱한 크기로 화면 밖에 놓여 hover가 죽는다)
- 진단 로그(`os.Logger`, debug 레벨)와 디버그 실행 옵션 `-DoItDebugAutoOn`은 T-003까지 유지한다.

### 3.3 Hover 감지
- 패널 content view의 **`NSTrackingArea`** (`.mouseEnteredAndExited`, `.activeAlways`)
- 진입 → 즉시 펼침, 이탈 → **0.1초 유예 뒤 접힘**(`NotchViewModel.exitGraceSeconds`, 일회성 지연, T-008). 유예 중 다시 들어오면 취소. 0.1초보다 길게 하려면 이 문서를 먼저 고친다
- 프레임 변경 직후 **150ms 안**에 온 이탈은 이벤트 좌표 대신 그 순간 실제 마우스 위치를 **1번** 읽어 판정(이벤트당 1회, 주기 확인 아님, T-008)
- 화면 구성 변경(`didChangeScreenParametersNotification`)은 **노치 위치·크기가 실제로 바뀐 경우에만** 펼침·입력·알림을 정리하고 애니메이션 없이 접는다(입력 중 글자는 유지). 바뀌지 않았으면 프레임만 다시 맞춘다(T-008)
- 마우스 위치를 주기적으로 읽는 방식 금지

### 3.4 NotchViewModel — 상태 머신
- `enum NotchState { off, idle, expanded, editing }`
- 전환 규칙은 PRD F3이 기준. 상태 전환은 한 곳(뷰모델)에서만 일어난다
- 애니메이션
  - 펼침: 즉시 시작, spring (response ≈ 0.3, damping ≈ 0.8)
  - 접힘: 내용 opacity → 0 먼저, 이후 높이·너비가 노치 크기로 줄며 위로 사라짐 (easeIn ≈ 0.4초)
- `NotchShape`: 노치 모양 (윗변이 메뉴바와 이어지고, 아랫모서리가 둥근 형태)

### 3.5 TodoStore (T-002)
- `@Observable` 단일 저장소. 뷰는 여기서만 읽고 쓴다
- `~/Library/Application Support/DoIt/todos.json`, `schemaVersion` 포함
- 원자적 쓰기, 연속 변경은 짧게 디바운스 후 저장

### 3.6 알림 (T-005) — PRD F8 노치 알림
- **ReminderPlanner**(순수 함수): (내 할 일, LMS 현재 목록, LMS 체크 상태, 알림 설정, 지금 시각) → 날짜별 요약 `[(날짜 09:00, 제목, 본문, id = "doit-day-YYYYMMDD")]`, 앞으로 30일치. 노치 알림과 대신 예약 알림이 **같은 계획**을 쓴다
- **NotchAlertScheduler** (앱 실행 중)
  - 다음 알림 시각 1개만 기억하고 **`DispatchSourceTimer` 일회성(wall-clock, `DispatchWallTime`) 1개**로 기다린다. 울리면 다음 것 1개를 다시 건다 → **§5 예외(D-015)**: 반복 타이머가 아닌 "다음 예정 시각까지 1회" 대기. 동시에 2개 이상 걸지 않는다
  - 재계산 시점(타이머 재설정): 앱 실행, 저장소·LMS·체크·기록 정리·알림 설정 변경, `NSCalendarDayChanged`, `NSWorkspace.didWakeNotification`
  - 깨어날 때: 오늘 9:00이 지났고 오늘 알림을 아직 안 보였으면 바로 표시 (마지막 표시 날짜를 UserDefaults에 기록해 하루 1번 보장)
- **노치 알림 표시**: 상태 머신에 `alert` 표시 이벤트를 추가한다(새 상태 또는 기존 expanded와 구분되는 모양). 규칙:
  - IDLE·OFF(앱 실행 중)일 때 표시. EXPANDED·EDITING 중이면 패널 맨 위에 같은 내용을 강조 표시하고 노치 알림은 생략
  - 5초 일회성 지연 후 자동으로 줄어듦, `×`는 즉시 닫힘, hover/클릭은 일반 펼침으로 전환(OFF 상태에서도 이 순간은 펼침 허용, 접히면 다시 OFF 규칙)
  - 모양·크기는 DESIGN.md "노치 알림". 프레임 변경 규칙(§3.2) 준수
- **대신 예약(Fallback)**: `applicationWillTerminate`에서 ReminderPlanner 결과를 `UNUserNotificationCenter` + `UNCalendarNotificationTrigger`로 예약(id `doit-day-`). 앱 실행 시 `doit-day-` 대기 알림을 전부 삭제. 강제 종료·충돌 시에는 예약되지 않음(알려진 한계)
- 권한: `requestAuthorization([.alert, .sound])`는 앱 실행 시 미결정일 때만. 거부여도 노치 알림은 동작
- 알림 내용은 과제명·과목명만 (맥 안에서만 표시)
- **로그 등급 (T-013)**: 실제 사용 중 나중에 확인할 수 있도록 `alert timer fired`·`alert shown`·`did wake`·`alert skipped: …`(일시 중지·오늘 마감 없음·이미 표시)·`test alert shown`은 **`.notice`**(디스크에 남는 등급)로 남긴다. 다음 예정 계산(`next alert`, `no upcoming alert`)은 `.debug` 유지. 날짜·개수만 public, 제목·과목명은 남기지 않는다

### 3.7 전체 편집기 (T-006) — PRD F9
- 앱 번들에 포함된 HTML/JS/CSS(`DoIt/Editor/Web/`)를 `WKWebView` 창에 `loadFileURL(_:allowingReadAccessTo:)`로 로드 (읽기 허용은 그 폴더만)
- 로컬 HTTP 서버 없음. **네트워크 차단(D-016)**: 외부 스크립트·CDN·웹 글꼴 금지, CSP(`default-src 'none'` 기반, 앱 파일만 허용), `WKNavigationDelegate`에서 `file:` 외 이동은 모두 취소, `WKWebsiteDataStore.nonPersistent()`
- **브리지**: 웹 → 앱은 `WKScriptMessageHandler` 하나(`doit`), 메시지 `{type, …}`. 앱 → 웹은 `callAsyncJavaScript(arguments:)`로 상태 JSON을 인자로 넘긴다(문자열 이어붙이기로 JS를 만들지 않음)
  - 앱은 웹에서 온 메시지를 **믿지 않고 검사**한다: 알 수 없는 type 무시, id가 실제로 있는지, 제목 빈칸·길이, 날짜 `yyyy-MM-dd`
  - 저장은 항상 TodoStore / LmsStore를 거친다. LMS는 `toggleCheck`만 연결(D-011)
  - 웹에서 제목은 `textContent`로만 넣는다(`innerHTML` 금지)
- **변경 알림**: `TodoStore.onTodosChanged`·`LmsStore.onChange`는 이미 노치 알림 스케줄러가 쓰므로 **덮어쓰지 않는다** → 여러 곳이 받을 수 있게 바꾸거나 기존 콜백에 이어 붙인다
- **색**: CSS에 hex를 쓰지 않는다. 앱이 Asset Catalog 역할 색을 읽어 CSS 변수로 넘기고, 창의 밝기 모드가 바뀌면(이벤트) 다시 넘긴다 (§3.0 원칙 유지)
- 창은 하나만. 닫으면 WebView를 해제(메모리 반납). `NSApp.activate`는 사용자가 메뉴·패널 버튼으로 편집기를 열 때만(설정 창과 같은 예외)

### 3.8 LMS 연동 (T-007) — PRD F11
- **피드 주소 검증**: `https://`이고 경로에 `/feeds/calendars/`가 있고 `.ics`로 끝나는 주소만 저장한다 (일반 LMS 페이지 주소를 넣어 다른 페이지에 접속하는 일을 막음)
- **피드 주소 저장 (T-013, D-009·D-018)**: `~/Library/Application Support/DoIt/lms-feed-url` 파일 1개에 주소 문자열(UTF-8)만 저장·읽기·삭제
  - 파일 권한 **600**, `DoIt/` 폴더 **700**. 쓰기는 같은 폴더에 **처음부터 600으로 만든 임시 파일**에 쓴 뒤 rename(원자적, 권한이 넓은 순간이 없게)
  - 쓸 때마다 `isExcludedFromBackup = true` (rename으로 새 파일이 되므로 매번). 읽을 때 일반 파일이 아니거나(심볼릭 링크 등) 소유자가 본인이 아니면 거부, 권한이 600보다 넓으면 600으로 고친다
  - 저장 공간 화면(`StorageReport`)·기록 정리 백업(`archive/`)·'모든 기록 초기화'는 이 파일을 다루지 않는다. LMS 연결 해제 때만 삭제
  - **이전**: 파일이 없고 예전 키체인 항목(`kSecClassGenericPassword`, service `com.personal.doit.lms-feed`)이 있으면 1번 읽어 파일에 쓰고, 파일 쓰기가 성공한 뒤에만 키체인 항목을 삭제. 실패하면 키체인을 그대로 두고 다음 실행 때 다시 시도
  - 주소는 메모리에만 잠깐 두고, 로그에는 `privacy: .private`로도 남기지 않는다(호스트 이름만 public 허용)
- **LmsSyncService**: 피드 1개를 GET
  - **`URLSessionConfiguration.ephemeral`** 사용: 쿠키 저장소 없음, 디스크 캐시 없음(응답·URL이 `~/Library/Caches`에 남지 않게), `httpShouldSetCookies = false`
  - HTTPS만 허용. 리디렉트는 **같은 호스트일 때만** 따라가고, 다른 호스트로 가면 중단 후 `invalidFeed`
  - User-Agent는 일반 문자열(`DoIt/<버전> (personal calendar subscription)`). 이메일 등 개인정보를 넣지 않는다
  - 응답 크기 상한 5MB, 넘으면 중단
  - 가능하면 `ETag`/`If-None-Match`, `Last-Modified`/`If-Modified-Since` 사용 (304면 캐시 유지)
  - 타임아웃 15초, 재시도는 다음 동기화 시점까지 미룸 (자동 반복 재시도 금지)
  - 동기화 트리거: 앱 실행 / `NSWorkspace.didWakeNotification` / 패널 펼침 → **마지막 동기화 후 6시간 미만이면 건너뜀**. 메뉴 "지금 새로고침"은 6시간 제한 무시, **최소 5분 간격**. 진행 중이면 무시. 실패한 경우도 '마지막 시도 시각'으로 기록해 같은 간격을 지킨다(실패 시 연타 방지)
  - 응답 상태 → 오류 상태 매핑: 401·403·404 → `disconnected`, 네트워크 오류·5xx → `offline`, 파싱 실패 → `invalidFeed`, **429 → `rateLimited`**
  - **429(요청 과다)를 받으면**: `Retry-After` 헤더가 있으면 그 시간, 없으면 **24시간** 동안 자동·수동 동기화를 모두 멈추고 캐시만 보여준다. 자동 재시도 없음. 연속 429가 오면 멈춤 시간을 두 배로 늘린다
  - 요청은 항상 1개씩(동시 요청 없음)
- **IcsParser**: 외부 패키지 없이 직접 구현
  - 줄 접기(unfolding), `VEVENT`의 `UID`, `SUMMARY`, `DTSTART`/`DTEND`(DATE, DATE-TIME, `TZID`, UTC `Z`), 이스케이프(`\,` `\;` `\n`) 처리
  - **읽는 속성은 `UID`, `SUMMARY`, `DTSTART`, `DTEND`뿐**(허용 목록 방식). `DESCRIPTION`, `X-ALT-DESC`, `URL`, `ATTACH` 등 나머지는 줄 단위로 건너뛰고 메모리에도 남기지 않는다 (강의자료 링크 포함)
  - 과제 판별: `UID`가 `event-assignment-`로 시작하는 `VEVENT`만 남긴다. 나머지는 개수만 로그
  - 제목 분리: `SUMMARY`의 **맨 끝 `[...]`** 를 과목명, 그 앞을 과제명으로. 대괄호가 없으면 과목명 없음
  - 날짜: `DTSTART;VALUE=DATE:20261009T000000`처럼 **VALUE=DATE인데 시각이 붙어 오는 경우가 있다** → 앞 8자리만 날짜로 쓰고 시각 없음. `...Z`(UTC)나 `TZID`가 있는 DATE-TIME은 **로컬 시간대로 바꾼 뒤** 날짜·시각을 정한다 (UTC 날짜를 그대로 쓰면 하루 어긋날 수 있음)
  - 과제(마감) 항목만 남기고(판별 규칙은 실제 피드 형태 확인 후 확정), `DESCRIPTION` 등 본문은 파싱 단계에서 버림
  - 마감이 오늘 이후 ~ 8주인 과제 → `lms.json`, **마감이 지난 과제 → `lms-history.json`으로 upsert**(T-009). 화면 표시는 설정한 N주로 거름
- **LmsStore**: `lms.json`(캐시, 통째로 교체·원자적 쓰기) + `lms-state.json`(체크 상태) + `lms-history.json`(T-009). `TodoStore`와 별개
- **읽기 전용 영구 규칙(D-011)**: LMS로 나가는 요청은 피드 GET 1종뿐. 요청 본문·사용자 데이터 전송 코드 금지 (테스트로 고정됨)

### 3.9 기록 보관·정리 (T-009) — PRD F13·F14
- **HistoryPolicy**(순수 함수): 오늘·보관 기간·항목들 → 정리 대상 목록·개수·예상 크기. 완료 안 한 내 할 일은 절대 대상이 아님
- **정리 실행**: 사용자 확인 후에만. (백업 선택 시) `archive/기록-YYYYMMDD.json`에 대상만 원자적으로 쓴 뒤 → 각 저장소에서 삭제·저장. 백업 쓰기가 실패하면 삭제하지 않는다
- 정리 필요 여부 계산 시점: 앱 실행, 날짜 변경(`NSCalendarDayChanged`), 설정 창 열 때 (타이머 없음)
- **StorageReport**: 파일 크기(`FileManager` 속성)·항목 수·메모리 사용량(`task_info`의 phys_footprint)을 설정 창을 열 때·새로고침 버튼 누를 때만 계산

### 3.10 달력 보기 (T-009) — PRD F12
- 패널 모드: `list` / `calendar`. 접힘이 끝나면 `list`로 초기화. 모드 전환은 상태 머신의 펼침·접힘 규칙에 영향 없음, 달력 안 입력창·날짜 선택은 기존 EDITING 규칙
- **CalendarModel**(순수 함수): 월 → 6×7 날짜 칸, 날짜별 (내 할 일, LMS 현재, LMS history) 집계, 날짜가 오늘 이전인지(읽기 전용) 판정
- 높이는 `PanelLayout` 순수 함수에 달력 모드 추가. 프레임 변경 규칙(§3.2) 준수
- **테스트**: 직접 만든 가짜 `.ics` 파일만 fixture로 쓴다. **실제 피드 파일·주소는 저장소에 넣지 않는다** (`.gitignore`에 `*.ics` 추가, fixture 폴더만 예외)

### 3.11 업데이트 (T-012b 구현 완료, PRD F16)
- 앱 수명의 업데이트 서비스 1개가 `SPUStandardUpdaterController`를 보유한다. LMS 저장소·동기화 서비스·편집기에는 접근하지 않는다. 메뉴·설정은 이 서비스에만 연결한다.
- `canCheckForUpdates`·자동 확인 설정은 Sparkle 공개 API와 관찰로 반영한다. 메뉴의 `autoenablesItems = false`와 재생성 구조에 주의한다. 관찰 해제·수명 관리, 진행 중 중복 요청 방지, 사용자 선택 영속화를 검증한다.
- 기본값은 Info.plist에 둔다: `SUEnableAutomaticChecks=YES`, `SUScheduledCheckInterval=86400`, `SUEnableSystemProfiling=NO`, `SUAutomaticallyUpdate=NO`, `SUAllowsAutomaticUpdates=NO`, `SUVerifyUpdateBeforeExtraction=YES`. `SUPublicEDKey`만 앱에 포함하며 개인 키는 개발자 로그인 키체인·저장소 밖 암호화 백업에 둔다. 학생에게 키체인 사용·개발자 키 설치를 요구하지 않는다.
- appcast·다운로드 이외의 요청 매개변수·분석·추적·사용자 데이터 업로드 금지. LMS용 URLSession·쿠키·주소 저장소·네트워크 제한은 수정하지 않는다.
- 정식 appcast는 https://prestige-kim.github.io/DoIt/appcast.xml. T-012e-2에서 번들 bool DoItDistributionEnabled=false를 추가해 유효 주소·공개 키와 **공개 준비 완료**를 분리한다(구현·검증 완료, 현재 기본값 false). false/missing/잘못된 타입에서는 정식 updater start/check·package/release를 차단, 일반 앱 사용은 가능. defaults/환경/인자로 해제 불가. true 전환은 별도 사용자 발행 승인 뒤 수행한다. 검증 구성은 기존 compile+plist+loopback 조건을 유지한다.
- 내부 로컬 검증은 Release와 구분되는 전용 구성(예: UpdateValidation, Release 기반 최적화)에서만 컴파일한다. loopback에만 서버를 열고 샘플 feed·서명 zip만 제공한다. 로컬 HTTP가 필요하면 해당 구성에만 최소 ATS 예외를 적용한다. 정식 Release는 실행 인자·환경·defaults로 로컬 피드를 켤 수 없어야 하며 검증 구성은 배포용 package가 거부한다.
- 자체 서명(D-017)과 번들 ID는 유지한다. 프레임워크·helper의 서명·실행 요구는 고정 버전의 공식 문서·실제 빌드로 검증한다. Sparkle 창 활성화는 업데이트 안내에 한정한 예외이며 노치 경로 활성화는 계속 금지한다.

## 4. 데이터 흐름
```
[노치 패널 UI] ─┐
                ├─> TodoStore ──> todos.json
[전체 편집기]  ─┘       │
                        └──> ReminderScheduler ──> macOS 알림

[피드 주소 파일(600)] ──> LmsSyncService ──HTTPS──> LMS 캘린더 피드(.ics)
                              │
                              └──> IcsParser ──> LmsStore ──> lms.json / lms-state.json
                                                    │
                                                    └──> 노치 패널 "LMS" 칸
```

## 5. 성능 금지 규칙 (반드시 지킬 것)
1. 마우스 위치·상태를 **타이머로 주기적으로 확인 금지** (`Timer`, `DispatchSourceTimer`, `NSEvent.mouseLocation` 폴링)
   - 예외 D-015: 노치 알림의 '다음 예정 시각까지 1회' 대기 타이머 1개(§3.6)
   - 예외 D-020: Sparkle 내부의 업데이트 예약 확인(86400초). 앱 자체 반복 타이머·폴링은 추가하지 않는다.
   - 예외: "켜기 시 3초 후 접힘", "알림 강조 3초" 같은 **일회성** 지연은 허용 (`Task.sleep` / `DispatchQueue.main.asyncAfter`)
2. **계속 다시 그려지는 뷰 금지** (`TimelineView`, 무한 반복 애니메이션)
3. 접혀 있을 때 무거운 효과 금지 (블러·그림자는 펼친 상태에서만)
4. 파일 감시·저장 루프 금지 (저장은 변경 시에만)
5. 네트워크 접근 금지 — 예외 D-008: LMS 개인 피드 GET(§3.8), 예외 D-020: 업데이트 appcast·GitHub Releases 다운로드 및 전용 구성의 loopback 검증(§3.11). LMS를 주기 타이머로 폴링하지 않는다.

## 6. 오픈소스 참고 규칙
| 프로젝트 | 라이선스 | 허용 범위 |
|---|---|---|
| NotchDrop, NotchNotification (Lakr233) | MIT | 구조 참고 및 코드 차용 가능. 차용 시 `THIRD_PARTY_NOTICES.md`에 출처·라이선스 표기 |
| Boring Notch (TheBoredTeam) | GPL-3.0 | **코드 복사 금지.** 동작 방식 이해를 위한 열람만 |
| Sparkle 2 (sparkle-project) | 배포본의 공식 라이선스·포함 고지 보존 | D-019에 한해 SPM 패키지 통합 허용, 고정 버전의 전체 라이선스·제3자 고지를 확인 |
| 그 외 | — | 사용 전 보고서로 문의 |

## 7. 결정 기록
| ID | 결정 | 이유 |
|---|---|---|
| D-001 | 네이티브 Swift(SwiftUI+AppKit) | 노치 패널·hover·알림을 가장 가볍게 구현 |
| D-002 | 자체 JSON 저장, 미리알림 연동 안 함 | PRD §11 |
| D-003 | 전체 편집기는 앱 내 WKWebView, 서버 없음 | 서버 수명 관리 문제 제거, 화면 전환 최소화 |
| D-004 | XcodeGen | `.pbxproj` 직접 수정으로 인한 프로젝트 손상 방지 |
| D-005 | 메인 디스플레이 = `NSScreen.screens.first` | 메뉴바가 있는 화면 기준 |
| D-006 | 마감일 미지정 → 생성일로 고정 | PRD §6 |
| D-007 | Swift 5 언어 모드 | Swift 6 동시성 검사로 인한 마찰 최소화 |
| D-008 | LMS 네트워크 예외: 피드 주소 1곳, 이벤트 시점에만, 최소 6시간 간격(수동은 5분). 업데이트 예외는 D-020으로 분리 | 자원 소모·보안 범위 최소화, LMS 서버 부담을 일반 캘린더 구독 수준으로 유지 |
| D-009 | LMS 피드 주소는 비밀번호처럼 취급: **이 맥의 본인만 읽는 파일 1개**에만 저장(T-013부터. T-010까지는 키체인 → D-018), 로그·화면·백업·git에 남기지 않음 | 주소 자체가 인증 수단(비밀번호급) |
| D-010 | LMS 데이터는 `lms.json`(읽기 전용 캐시) + `lms-state.json`(체크 상태)으로 `todos.json`과 분리 | 동기화가 사용자 할 일을 덮어쓰는 사고 방지 |
| D-011 | LMS 읽기 전용: GET 1종만, 사용자 데이터 외부 전송 금지 (영구) | 학교 공지·보안 원칙 |
| D-012 | 지난 LMS 과제는 `lms-history.json`에 DoIt이 직접 보관 | 피드가 지난 과제를 오래 주지 않음 (2026-11-07 확인: 가장 오래된 항목 10/9) |
| D-013 | 기록은 자동 삭제하지 않고, 보관 기간 초과 시 알림 → 사용자 확인 후 정리(백업 선택 가능) | 사용자 데이터 보호 |
| D-015 | 알림은 노치 알림(앱이 직접 그림), 다음 9:00까지 일회성 타이머 1개, 앱 종료 시에만 macOS 기본 알림 대신 예약 | 사용자 요청(다이나믹 아일랜드 방식), 자원 최소 |
| D-017 | **서명: 자체 서명 인증서 1개로 Debug·Release 모두 서명**(T-010부터 고정, Apple 개발자 등록 없음). 번들 ID `com.personal.doit` 유지 | 배포 사용자의 인증 횟수 최소화(업데이트 후 키체인·권한이 같은 앱으로 유지되도록 서명 표시를 고정). 인증서·개인 키는 저장소 밖 암호화 백업 필수 |
| D-014 | 429 연속 시 멈춤 시간 2배, 상한 7일 (서버가 더 길게 요구하면 그 값) | T-007 결정 승인 |
| D-016 | 전체 편집기 WebView는 네트워크 차단(CSP·이동 취소·비영구 저장소), 브리지 메시지는 앱에서 검사, LMS는 체크만. **WebView 기본 바탕 끄기는 비공개 KVC `drawsBackground`(유일한 비공개 키 사용처, `responds(to:)` 확인 후 없으면 건너뜀)** | 웹 화면이 외부와 통신하거나 LMS 데이터를 바꾸는 일 방지 / 다크 모드 흰색 번쩍임 방지(T-006). App Store 배포가 아니므로 허용, macOS 업데이트 때 동작 재확인 |
| D-018 | **피드 주소를 키체인 대신 파일에 저장**(§3.8: `lms-feed-url`, 파일 600·폴더 700, 600 임시 파일 → rename, Time Machine 백업 제외, 심볼릭 링크·다른 소유자 거부). 기존 키체인 항목은 1번 옮긴 뒤 삭제 | 자체 서명(D-017)은 Team ID가 없어 키체인 접근 목록이 빌드 지문(cdhash)으로 기록됨 → 업데이트마다 로그인 암호 창 1번(T-010 실측). 배포 사용자 인증 횟수 최소화 목표가 우선. 대가: 같은 사용자 계정의 다른 프로그램이 읽을 수 있음 — 주소로 가능한 일은 과제 목록 읽기뿐이고 노출 시 LMS에서 재발급 가능 (2026-11-08 사용자 결정) |
| D-019 | 외부 패키지 예외는 Sparkle 2 하나, 공식 SPM 바이너리 배포·정확한 버전 고정. **2.10.1 exactVersion 고정**(T-012b 보안 공지 재검토 반영) | 업데이트 기능·서명 검증을 직접 구현하지 않고 유지되는 프레임워크 사용 |
| D-020 | 업데이트 전용 네트워크: 지정 HTTPS appcast 1곳 + 프로젝트 GitHub Releases와 필수 자산 리디렉트. 시스템 프로파일 끔, 사용자 데이터 전송 금지. Sparkle 내부 86400초 예약만 반복 타이머 금지의 예외. loopback은 전용 검증 구성에서만 | 업데이트 후 학생의 인증 횟수 최소화를 실측하고 LMS GET 영구 규칙과 분리 |

## 8. 릴리스 도구 (T-012c 구현·로컬 검증 완료)
- 깨끗한 main과 정식 업데이트 설정을 검사한 뒤 project.yml의 버전/빌드만 갱신하고 Release 빌드·포장·EdDSA 검증을 수행한다. 실패 시 자기 변경만 복구하며 사용자 파일·기존 산출물은 덮어쓰지 않는다. 커밋·태그·업로드·설치는 자동 실행하지 않는다.
- 개인 키는 기존 개발자 키체인 account만 사용하고 앱 공개 키와 서명 키의 일치를 검증한다. zip 내부 앱의 버전·서명·구성, zip의 크기/해시/EdDSA, appcast 후보와 manifest의 일치를 확인한다.
- 후보는 dist에 둔다. site/appcast.xml을 미리 수정하지 않으며 zip 업로드·검증 뒤 반영한다. 정식 공개 준비 미완/검증 구성은 계속 포장 거부. 정상 경로 시험은 임시 저장소로 제한한다.
- 공개 운영 안내는 docs/RELEASING.md, 내보내기는 이 파일만 추가 허용하며 나머지 비공개 문서 제외 원칙을 유지한다.

## 9. 랜딩 사이트 (T-012d 로컬 구현·사용자 확인 완료)
- site/에 정적 HTML/CSS/로컬 JS/SVG와 자체 자산만 둔다. 로컬 JS로 허구 제품 시연·스크롤 챕터·접근성 상태를 구현하는 것은 허용한다. 앱의 네트워크/타이머/저장 구조를 바꾸는 예외가 아니다.
- 실제 LMS 연결·주소 입력·로그인·할 일 데이터 수집·영속 저장·외부 분석/API 없음. 디자인 생성 도구에 주는 입력은 공개 설명과 허구 자료만, 완성 사이트 런타임은 외부 AI에 접속하지 않는다.
- 자연 스크롤·기능 버튼 시연, 긴 sticky/스크롤 자동 전환 없음. 유한 알림 timeout과 사용자 실시간 시계 요청에 한정한 보이는 무대의 분 경계 timeout 하나 재예약을 허용, 무대/탭 숨김 시 취소. 앱 폴링/타이머 예외로 확대하지 않음. 무한 rAF·scroll hijacking 금지, JS 없음/motion 감소/작은 화면 fallback 유지.
- 저장소 prestige-kim/DoIt 및 Pages URL은 확정하되 releasePublished=false·다운로드 비활성 안내를 유지한다. 버전별 Releases 자산 URL은 릴리스 도구 이름 규칙과 일치시킨다. 임의 latest 자산을 가정하지 않는다. site에는 로컬 manifest·원본 SHA·실제 appcast 후보를 자동 복사하지 않는다.
- Pages 워크플로는 site만 대상으로 수동 실행+기본 비활성 gate로 준비한다. 이번 작업은 코드 준비·로컬 검증뿐이며 push/Actions 실행/Pages 활성화 없음. 실제 게이트 개방은 사용자 발행 승인 뒤 별도 단계다.
