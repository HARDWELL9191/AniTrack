; AniReco installer additions.
;
; The app was called AniTrack before. AniReco installs to its own folder, so the old AniTrack
; install is removed first (silently, keeping its data; the app moves that data over on its
; first start). Names below that still say AniTrack refer to what older builds left behind.
;
; Earlier builds also used Windows' own language model through an identity package, with a
; certificate in Trusted People; remove that certificate (the app removes the package itself).
; The AI writer that replaced it needs nothing installed: the app downloads its model on request.

!macro NSIS_HOOK_PREINSTALL
  ; Same registry view and context as the old installer wrote (both come from Tauri's template).
  ReadRegStr $R0 SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\AniTrack" "InstallLocation"
  ${If} $R0 != ""
    ; Stored with quotes around it.
    StrCpy $R1 $R0 1
    ${If} $R1 == '"'
      StrCpy $R0 $R0 -1 1
    ${EndIf}
    ${If} ${FileExists} "$R0\uninstall.exe"
      DetailPrint "Removing the old AniTrack app (your data is kept)"
      ; /S: silent, which also leaves the app data alone. _?= runs it in place so we wait for it.
      ExecWait '"$R0\uninstall.exe" /S _?=$R0' $R1
      Delete "$R0\uninstall.exe"
      RMDir "$R0"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToLog 'certutil.exe -delstore TrustedPeople "AniTrack"'
  Pop $0
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-AppxPackage -Name AniTrack.WindowsAI | Remove-AppxPackage"'
  Pop $0
!macroend
