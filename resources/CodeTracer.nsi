; CodeTracer Windows installer — NSIS 3.x script.
;
; The codetracer reprobuild recipe drives this script via its
; `windows-installer` build action; the action stages the prebuilt
; CodeTracer tree at `non-nix-build/CodeTracer-win/` and then invokes
; `makensis -DAPP_VERSION=<X.Y.Z> resources/CodeTracer.nsi`, which
; bundles that tree into `non-nix-build/CodeTracer-Setup.exe`.
;
; Defines the recipe passes in:
;   APP_VERSION  — codetracer version string (year.month.build),
;                  derived from src/ct/version.nim
;   STAGING_DIR  — absolute path to non-nix-build/CodeTracer-win
;   OUT_FILE     — absolute path to non-nix-build/CodeTracer-Setup.exe
;
; Defaults below let `makensis CodeTracer.nsi` run standalone for
; ad-hoc smoke-testing without the recipe; in that case the staged
; tree is expected at ../non-nix-build/CodeTracer-win/ relative to
; this script (i.e. the codetracer repo root).

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif

!ifndef STAGING_DIR
  !define STAGING_DIR "..\non-nix-build\CodeTracer-win"
!endif

!ifndef OUT_FILE
  !define OUT_FILE "..\non-nix-build\CodeTracer-Setup.exe"
!endif

; ICON_PATH defaults to the in-repo `resources/` copy. With ``-NOCD``
; the working dir is the codetracer repo root, so the relative path
; from there is ``resources/CodeTracer.ico``. Without ``-NOCD`` the
; working dir is ``resources/`` and the bare filename works; both
; cases are covered by the conditional default below.
!ifndef ICON_PATH
  !define ICON_PATH "resources\CodeTracer.ico"
!endif

; LICENSE_PATH same story — the MUI license page reads the file at
; compile time, so the path resolves against the makensis cwd, not
; the .nsi's location. The recipe-driven path passes the repo-root-
; absolute path; the standalone smoke path defaults to the
; repository's top-level LICENSE.
!ifndef LICENSE_PATH
  !define LICENSE_PATH "LICENSE"
!endif

!define APP_NAME            "CodeTracer"
!define APP_PUBLISHER       "Metacraft Labs"
!define APP_URL             "https://codetracer.com"
!define APP_EXE             "bin\ct.exe"
!define APP_LAUNCH_NAME     "CodeTracer"
!define UNINSTALL_REG_ROOT  "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
!define APP_REG_ROOT        "Software\${APP_PUBLISHER}\${APP_NAME}"

; -----------------------------------------------------------------
; Modern UI 2 setup
; -----------------------------------------------------------------
!include "MUI2.nsh"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUT_FILE}"
Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "${APP_REG_ROOT}" "InstallDir"
ShowInstDetails show
ShowUnInstDetails show

VIProductVersion             "0.0.0.0"
VIAddVersionKey ProductName  "${APP_NAME}"
VIAddVersionKey CompanyName  "${APP_PUBLISHER}"
VIAddVersionKey FileDescription "${APP_NAME} installer"
VIAddVersionKey LegalCopyright  "(C) Metacraft Labs"
VIAddVersionKey FileVersion     "${APP_VERSION}"
VIAddVersionKey ProductVersion  "${APP_VERSION}"

!define MUI_ABORTWARNING
!define MUI_ICON   "${ICON_PATH}"
!define MUI_UNICON "${ICON_PATH}"

; Pages: welcome → license → install dir → install → finish
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_PATH}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${APP_NAME}"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

; -----------------------------------------------------------------
; Sections
; -----------------------------------------------------------------
Section "${APP_NAME} (required)" SecMain
  SectionIn RO

  SetOutPath "$INSTDIR"
  ; Recursively copy the staged tree the recipe assembled. The
  ; `/r` flag makes NSIS walk subdirectories; the trailing `\*.*`
  ; copies all files at every depth.
  File /r "${STAGING_DIR}\*.*"

  ; Persist the install root so subsequent installs default to the
  ; same directory and so the uninstaller can find its target.
  WriteRegStr HKLM "${APP_REG_ROOT}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APP_REG_ROOT}" "Version"    "${APP_VERSION}"

  ; Add/Remove Programs entry.
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "DisplayName"     "${APP_NAME}"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "URLInfoAbout"    "${APP_URL}"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "${UNINSTALL_REG_ROOT}" "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegDWORD HKLM "${UNINSTALL_REG_ROOT}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_REG_ROOT}" "NoRepair" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Start Menu shortcut" SecStartMenu
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut  "$SMPROGRAMS\${APP_NAME}\${APP_LAUNCH_NAME}.lnk" \
                  "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}"
  CreateShortCut  "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" \
                  "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortCut "$DESKTOP\${APP_LAUNCH_NAME}.lnk" \
                 "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}"
SectionEnd

; -----------------------------------------------------------------
; Section descriptions (shown in the components page if we add one)
; -----------------------------------------------------------------
LangString DESC_SecMain      ${LANG_ENGLISH} "${APP_NAME} binaries, frontend, Electron runtime and supporting files."
LangString DESC_SecStartMenu ${LANG_ENGLISH} "Create a Start Menu folder with the ${APP_NAME} launcher and uninstaller."
LangString DESC_SecDesktop   ${LANG_ENGLISH} "Create a desktop shortcut for ${APP_NAME}."

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain}      $(DESC_SecMain)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStartMenu} $(DESC_SecStartMenu)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop}   $(DESC_SecDesktop)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; -----------------------------------------------------------------
; Uninstaller
; -----------------------------------------------------------------
Section "Uninstall"
  ; Read the install dir the installer recorded; we walk it from the
  ; uninstaller's perspective so a relocated install still cleans up
  ; cleanly.
  ReadRegStr $INSTDIR HKLM "${APP_REG_ROOT}" "InstallDir"
  StrCmp $INSTDIR "" 0 +2
    SetOutPath "$EXEDIR"
    StrCpy $INSTDIR "$EXEDIR"

  ; Recursively remove the install root. NSIS does not provide a
  ; recursive directory delete that respects file count; the
  ; `/REBOOTOK` flag schedules pending deletes for reboot when a
  ; file is locked at uninstall time.
  RMDir /r /REBOOTOK "$INSTDIR"

  Delete "$SMPROGRAMS\${APP_NAME}\${APP_LAUNCH_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"
  Delete "$DESKTOP\${APP_LAUNCH_NAME}.lnk"

  DeleteRegKey HKLM "${UNINSTALL_REG_ROOT}"
  DeleteRegKey HKLM "${APP_REG_ROOT}"
SectionEnd
