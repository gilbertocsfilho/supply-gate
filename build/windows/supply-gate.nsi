; Supply Gate Windows installer (NSIS). Produces a single self-contained
; .exe, no MSI/WiX/dotnet toolchain needed to build or to run it.
;
; Payload and hook contract mirror build/deb/build-deb.sh and
; build/macos/build-macos-pkg.sh: install.ps1, uninstall.ps1, lib/windows/,
; shims/windows/, policy/default-policy.conf, README.md, GUIDE.md, VERSION.
; Install runs `install.ps1 apply -Scope machine -Mode <soft|hard>`
; (default soft, override with /MODE=hard on the command line -- same
; meaning as SUPPLY_GATE_MODE on the POSIX side) right after the payload is
; laid down, and aborts with a visible error if apply fails -- same
; "don't swallow the error" reasoning as debian/postinst. Uninstall runs
; `install.ps1 uninstall -Scope machine` before removing files (best
; effort: a failure there still lets removal proceed, matching
; debian/prerm's forgiving behavior).
;
; NSIS itself only ships a 32-bit installer stub, so this .exe runs under
; WOW64 on 64-bit Windows even though everything it manages is 64-bit-only.
; Two things exist specifically to route around that (see docs/windows-
; support.md's "the param() binding trap" note for the sibling class of
; bug this is -- correctness only provable by actually running the chain):
;   - PowerShell is invoked via the "Sysnative" alias, not System32 --
;     System32 from a WOW64 process is silently redirected to SysWOW64
;     (the 32-bit PowerShell), which then resolves $PSHOME/AllUsersAllHosts
;     paths under SysWOW64 too and quietly writes the machine-wide profile
;     to the wrong place. Sysnative bypasses that redirection.
;   - SetRegView 64 before writing the Add/Remove Programs entry, so it
;     lands in the real HKLM view instead of WOW6432Node.
;
; No wizard pages are authored on purpose (same reasoning as the MSI
; approach this replaced: fewest clicks, /S already gives a fully silent
; install with zero UI regardless).

!include "FileFunc.nsh"
!include "x64.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif

Name "Supply Gate"
OutFile "dist\SupplyGate-${VERSION}-setup.exe"
InstallDir "$PROGRAMFILES64\Supply Gate"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Supply Gate"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "Supply Gate installer"
VIAddVersionKey "CompanyName" "Supply Gate Maintainers"
VIAddVersionKey "LegalCopyright" "Supply Gate Maintainers"

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SupplyGate"

Var SYSPS
Var MODE

; Shared by both .onInit and un.onInit -- NSIS compiles the installer and
; uninstaller as two separate programs with separate init entry points, so
; this logic (and $SYSPS itself) has to be set in each explicitly or the
; uninstaller silently runs with an empty $SYSPS.
!macro ResolveSysPowerShell suffix
  ; Sysnative is the documented WOW64 escape hatch for a 32-bit process to
  ; reach the real (64-bit) System32 PowerShell; System32 alone would
  ; silently redirect to SysWOW64 here. Falls back to System32 on a
  ; genuine 32-bit OS, where no redirection exists in the first place.
  IfFileExists "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" 0 use_system32_${suffix}
    StrCpy $SYSPS "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    Goto ps_done_${suffix}
  use_system32_${suffix}:
    StrCpy $SYSPS "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  ps_done_${suffix}:
!macroend

Function .onInit
  !insertmacro ResolveSysPowerShell "inst"

  ${GetParameters} $R0
  ${GetOptions} $R0 "/MODE=" $MODE
  IfErrors 0 +2
    StrCpy $MODE "soft"
FunctionEnd

Function un.onInit
  !insertmacro ResolveSysPowerShell "uninst"
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"
  File "..\..\install.ps1"
  File "..\..\uninstall.ps1"
  File "..\..\README.md"
  File "..\..\GUIDE.md"
  File "..\..\VERSION"

  SetOutPath "$INSTDIR\lib\windows"
  File "..\..\lib\windows\SupplyGate.Common.psm1"
  File "..\..\lib\windows\SupplyGate.Checks.psm1"

  SetOutPath "$INSTDIR\shims\windows"
  File "..\..\shims\windows\manager-wrapper.ps1"

  SetOutPath "$INSTDIR\policy"
  File "..\..\policy\default-policy.conf"

  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall-SupplyGate.exe"

  SetRegView 64
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "Supply Gate"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "Supply Gate Maintainers"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall-SupplyGate.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall-SupplyGate.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; Deliberately not swallowed: an apply that fails here must fail the
  ; install visibly, not leave a host that Add/Remove Programs reports as
  ; "installed" while completely unenforced (same debian/postinst
  ; reasoning: a caught-and-ignored failure is worse than a loud one).
  DetailPrint "Applying Supply Gate policy (mode: $MODE)..."
  nsExec::ExecToLog '"$SYSPS" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" apply -Scope machine -Mode $MODE'
  Pop $0
  IntCmp $0 0 apply_ok
    ; /SD IDOK: auto-dismiss under /S so a silent/unattended install (the
    ; exact scenario /S exists for) fails fast instead of hanging forever
    ; on a dialog nobody is there to click.
    MessageBox MB_OK|MB_ICONSTOP "Supply Gate: applying the policy failed (exit code $0).$\r$\nRe-run manually to debug:$\r$\n$SYSPS -File $\"$INSTDIR\install.ps1$\" apply -Scope machine -Mode $MODE" /SD IDOK
    SetErrorLevel 1
    Abort
  apply_ok:
SectionEnd

Section "Uninstall"
  DetailPrint "Removing Supply Gate policy..."
  nsExec::ExecToLog '"$SYSPS" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" uninstall -Scope machine'
  Pop $0
  IntCmp $0 0 uninstall_ok
    DetailPrint "Supply Gate: uninstall hook failed (exit code $0); some managed blocks/state may remain"
  uninstall_ok:

  SetRegView 64
  DeleteRegKey HKLM "${UNINST_KEY}"

  Delete "$INSTDIR\install.ps1"
  Delete "$INSTDIR\uninstall.ps1"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\GUIDE.md"
  Delete "$INSTDIR\VERSION"
  Delete "$INSTDIR\lib\windows\SupplyGate.Common.psm1"
  Delete "$INSTDIR\lib\windows\SupplyGate.Checks.psm1"
  Delete "$INSTDIR\shims\windows\manager-wrapper.ps1"
  Delete "$INSTDIR\policy\default-policy.conf"
  Delete "$INSTDIR\Uninstall-SupplyGate.exe"
  RMDir "$INSTDIR\lib\windows"
  RMDir "$INSTDIR\lib"
  RMDir "$INSTDIR\shims\windows"
  RMDir "$INSTDIR\shims"
  RMDir "$INSTDIR\policy"
  RMDir "$INSTDIR"
SectionEnd
