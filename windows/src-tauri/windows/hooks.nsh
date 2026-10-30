; AniTrack installer additions.
; Earlier builds used Windows' own language model through an identity package, with a
; certificate in Trusted People; remove that certificate (the app removes the package itself).
; The AI writer that replaced it needs nothing installed: the app downloads its model on request.

!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToLog 'certutil.exe -delstore TrustedPeople "AniTrack"'
  Pop $0
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-AppxPackage -Name AniTrack.WindowsAI | Remove-AppxPackage"'
  Pop $0
!macroend
