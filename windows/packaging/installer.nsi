Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!include "LogicLib.nsh"
!include "MUI2.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\DoIt.Windows"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define APP_EXE "$INSTDIR\app\DoIt.Windows.exe"
!define PAYLOAD_MARKER ".doit-app-payload"

Name "DoIt ${VERSION}"
OutFile "${INSTALLER_OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\DoIt"
VIProductVersion "${VERSION}.${BUILD}"
VIAddVersionKey /LANG=1042 "ProductName" "DoIt"
VIAddVersionKey /LANG=1042 "FileDescription" "DoIt ${ARCH} 설치"
VIAddVersionKey /LANG=1042 "FileVersion" "${VERSION}.${BUILD}"
VIAddVersionKey /LANG=1042 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1042 "LegalCopyright" "DoIt contributors"
ShowInstDetails show
ShowUninstDetails show
SetOverwrite try

!ifndef LICENSE_FILE
  !error "LICENSE_FILE is required: package_windows.py builds the installer agreement"
!endif
; 사용권 동의: DoIt MIT와 함께 설치되는 Windows App SDK 사용 조건 원문. 동의해야 설치가 진행된다.
!define MUI_LICENSEPAGE_TEXT_TOP "설치하기 전에 DoIt과 함께 설치되는 구성요소의 사용권을 확인해 주세요."
!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!insertmacro MUI_PAGE_INSTFILES
; 완료 화면: 설치가 끝까지 성공했을 때만 보인다. 섹션에서 Abort하면 이 화면으로 넘어가지 않고,
; 조용한 설치(/S)는 화면이 없으므로 앱을 실행하지 않는다.
!define MUI_PAGE_CUSTOMFUNCTION_PRE FinishPagePre
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "DoIt 실행"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchInstalledApp
!define MUI_FINISHPAGE_NOREBOOTSUPPORT
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Korean"

Var SetupMutex
Var StageDirectory
Var InstallSucceeded
Var CleanupResult

!macro RequireClosed
  System::Call 'user32::FindWindowW(p 0, w "DoIt Tray") p .r0'
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "시계 옆 DoIt 아이콘에서 종료를 누른 뒤 다시 실행해 주세요." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!macroend

!macro InitializeScope
  SetShellVarContext current
  SetRegView 64
  StrCpy $INSTDIR "$LOCALAPPDATA\Programs\DoIt"
  System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\DoIt.Windows.Setup") p .r0 ?e'
  Pop $1
  StrCpy $SetupMutex $0
  ${If} $SetupMutex == 0
  ${OrIf} $1 == 183
    MessageBox MB_OK|MB_ICONEXCLAMATION "다른 DoIt 설치 또는 제거 작업이 열려 있습니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!macroend

!macro AssertOrdinaryDirectory PATH
  System::Call 'kernel32::GetFileAttributesW(w "${PATH}") i .r0'
  ${If} $0 != -1
    IntOp $1 $0 & 0x410
    ${If} $1 != 16
      MessageBox MB_OK|MB_ICONEXCLAMATION "DoIt 설치 폴더를 확인할 수 없습니다. 폴더와 파일을 그대로 두었습니다." /SD IDOK
      SetErrorLevel 2
      Abort
    ${EndIf}
  ${EndIf}
!macroend

!macro CheckManagedPaths
  !insertmacro AssertOrdinaryDirectory "$LOCALAPPDATA\Programs"
  !insertmacro AssertOrdinaryDirectory "$INSTDIR"
  !insertmacro AssertOrdinaryDirectory "$INSTDIR\app"
  !insertmacro AssertOrdinaryDirectory "$INSTDIR\previous"
  ${If} ${FileExists} "$INSTDIR\app\*.*"
  ${AndIfNot} ${FileExists} "$INSTDIR\app\${PAYLOAD_MARKER}"
    MessageBox MB_OK|MB_ICONEXCLAMATION "기존 DoIt 폴더를 이 설치 파일이 관리하는 폴더로 확인할 수 없습니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
  ${If} ${FileExists} "$INSTDIR\previous\*.*"
  ${AndIfNot} ${FileExists} "$INSTDIR\previous\${PAYLOAD_MARKER}"
    MessageBox MB_OK|MB_ICONEXCLAMATION "이전 설치의 폴더를 확인해 주세요. 폴더와 파일을 그대로 두었습니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!macroend

Function .onInit
  !insertmacro InitializeScope
  ${IfNot} ${AtLeastWin11}
    MessageBox MB_OK|MB_ICONEXCLAMATION "DoIt은 Windows 11에서 실행됩니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!if "${ARCH}" == "arm64"
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_OK|MB_ICONEXCLAMATION "이 설치 파일은 Arm64 Windows 11용입니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!else if "${ARCH}" == "x64"
  ${IfNot} ${IsNativeAMD64}
    MessageBox MB_OK|MB_ICONEXCLAMATION "이 설치 파일은 x64 Windows 11용입니다." /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!else
  !error "Unexpected installer architecture"
!endif
  !insertmacro RequireClosed
  !insertmacro CheckManagedPaths
FunctionEnd

Function un.onInit
  !insertmacro InitializeScope
  !insertmacro RequireClosed
  !insertmacro CheckManagedPaths
FunctionEnd

; NSIS's recursive RMDir follows directory reparse points. Inspect each directory
; before descending so a junction inside an old app payload cannot reach profile data.
!macro DefineDeleteAppDirectory PREFIX
Function ${PREFIX}DeleteAppDirectory
  Exch $0
  Push $1
  Push $2
  Push $3
  System::Call 'kernel32::GetFileAttributesW(w r0) i .r1'
  ${If} $1 == -1
    ClearErrors
    Goto finish
  ${EndIf}
  IntOp $2 $1 & 0x410
  ${If} $2 != 16
    SetErrors
    Goto finish
  ${EndIf}
  ClearErrors
  FindFirst $1 $2 "$0\*"
  ${IfNot} ${Errors}
    ${Do}
      ${If} $2 != "."
      ${AndIf} $2 != ".."
        StrCpy $3 "$0\$2"
        System::Call 'kernel32::GetFileAttributesW(w r3) i .r2'
        IntOp $2 $2 & 0x10
        ${If} $2 != 0
          Push $3
          Call ${PREFIX}DeleteAppDirectory
        ${Else}
          Delete "$3"
        ${EndIf}
        ${If} ${Errors}
          FindClose $1
          SetErrors
          Goto finish
        ${EndIf}
      ${EndIf}
      FindNext $1 $2
    ${LoopUntil} ${Errors}
    FindClose $1
  ${EndIf}
  ClearErrors
  RMDir "$0"
  ${If} ${FileExists} "$0\*.*"
    SetErrors
  ${EndIf}
finish:
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd
!macroend

!insertmacro DefineDeleteAppDirectory ""
!insertmacro DefineDeleteAppDirectory "un."

Section "설치"
  SetOutPath "$INSTDIR"
  ClearErrors
  ${If} ${FileExists} "$INSTDIR\previous\${PAYLOAD_MARKER}"
    ${If} ${FileExists} "$INSTDIR\app\${PAYLOAD_MARKER}"
      Push "$INSTDIR\previous"
      Call DeleteAppDirectory
    ${Else}
      Rename "$INSTDIR\previous" "$INSTDIR\app"
    ${EndIf}
    IfErrors failed
  ${EndIf}

  GetTempFileName $StageDirectory "$INSTDIR"
  IfErrors failed
  Delete "$StageDirectory"
  CreateDirectory "$StageDirectory"
  IfErrors failed
  SetOutPath "$StageDirectory"
!ifdef WINDOWS_COMPILER
  File /r "${PUBLISH_DIRECTORY}\*"
!else
  File /r "${PUBLISH_DIRECTORY}/*"
!endif
  IfErrors failed
  SetOutPath "$INSTDIR"
  System::Call 'user32::FindWindowW(p 0, w "DoIt Tray") p .r0'
  ${If} $0 != 0
    Goto failed
  ${EndIf}

  ${If} ${FileExists} "$INSTDIR\app\${PAYLOAD_MARKER}"
    Rename "$INSTDIR\app" "$INSTDIR\previous"
    IfErrors failed
  ${EndIf}
  Rename "$StageDirectory" "$INSTDIR\app"
  IfErrors restore_previous
  StrCpy $StageDirectory ""

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  IfErrors restore_old_app
  SetOutPath "$INSTDIR\app"
  CreateShortcut "$SMPROGRAMS\DoIt.lnk" "${APP_EXE}"
  IfErrors restore_old_app
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "DoIt"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}.${BUILD}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "${APP_EXE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  IfErrors restore_old_app

  SetOutPath "$INSTDIR"
  Push "$INSTDIR\previous"
  Call DeleteAppDirectory
  ClearErrors
  StrCpy $InstallSucceeded "1"
  Goto done

restore_old_app:
  SetOutPath "$INSTDIR"
  Push "$INSTDIR\app"
  Call DeleteAppDirectory
restore_previous:
  ${If} ${FileExists} "$INSTDIR\previous\${PAYLOAD_MARKER}"
    Rename "$INSTDIR\previous" "$INSTDIR\app"
  ${EndIf}
failed:
  SetOutPath "$INSTDIR"
  ${If} $StageDirectory != ""
    Push "$StageDirectory"
    Call DeleteAppDirectory
  ${EndIf}
  MessageBox MB_OK|MB_ICONEXCLAMATION "DoIt 설치를 완료하지 못했습니다. DoIt을 종료하고 다시 시도해 주세요." /SD IDOK
  SetErrorLevel 2
  Abort
done:
SectionEnd

; 설치가 끝까지 성공하지 않았으면 완료 화면을 건너뛴다(예비 확인).
Function FinishPagePre
  ${If} $InstallSucceeded != "1"
    Abort
  ${EndIf}
FunctionEnd

; 설치 프로그램은 RequestExecutionLevel user로 현재 사용자 권한에서 돌므로,
; Exec로 띄운 앱도 같은 사용자 권한으로 실행된다.
Function LaunchInstalledApp
  ${If} $InstallSucceeded == "1"
  ${AndIf} ${FileExists} "${APP_EXE}"
    SetOutPath "$INSTDIR\app"
    Exec '$\"${APP_EXE}$\"'
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetOutPath "$INSTDIR"
  !insertmacro RequireClosed
  ; 알림 등록·알림 예약 정리. 실패해도 앱 파일·바로가기·HKCU 항목 제거는 계속하고 끝에 알린다.
  StrCpy $CleanupResult "0"
  ${If} ${FileExists} "${APP_EXE}"
    ClearErrors
    ExecWait '$\"${APP_EXE}$\" --uninstall-cleanup' $0
    ${If} ${Errors}
      StrCpy $CleanupResult "실행 실패"
    ${ElseIf} $0 != 0
      StrCpy $CleanupResult $0
    ${EndIf}
    ClearErrors
  ${EndIf}
  ReadRegStr $0 HKCU "${RUN_KEY}" "DoIt"
  ${If} $0 == '$\"${APP_EXE}$\"'
    DeleteRegValue HKCU "${RUN_KEY}" "DoIt"
  ${EndIf}
  Push "$INSTDIR\app"
  Call un.DeleteAppDirectory
  IfErrors unfailed
  Push "$INSTDIR\previous"
  Call un.DeleteAppDirectory
  IfErrors unfailed
  Delete "$SMPROGRAMS\DoIt.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  Delete "$INSTDIR\Uninstall.exe"
  SetOutPath "$LOCALAPPDATA\Programs"
  RMDir "$INSTDIR"
  ${If} $CleanupResult != "0"
    MessageBox MB_OK|MB_ICONINFORMATION "DoIt을 제거했습니다. 알림 등록 정리를 끝내지 못했습니다. (코드 $CleanupResult)" /SD IDOK
  ${EndIf}
  Goto undone
unfailed:
  MessageBox MB_OK|MB_ICONEXCLAMATION "DoIt 앱 파일을 제거하지 못했습니다. DoIt을 종료하고 다시 시도해 주세요." /SD IDOK
  SetErrorLevel 2
  Abort
undone:
SectionEnd
