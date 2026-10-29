; AniTrack installer additions for Windows AI ("Why would I like this?" written by Windows'
; on-device language model). The installer runs with admin rights for these two steps:
;  - the Windows App SDK runtime the AI helper needs (downloaded from Microsoft if it is
;    missing, and only run when it is signed by Microsoft);
;  - trusting the certificate this build's identity package is signed with (Trusted People,
;    the store Windows checks for sideloaded packages; the certificate's private key was
;    deleted when the build finished, so it can't sign anything else).
; The identity package itself is registered by AniTrack for your user the first time it's needed.

!macro NSIS_HOOK_POSTINSTALL
  DetailPrint "Setting up Windows AI..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\winai\install_runtime.ps1"'
  Pop $0
  DetailPrint "Windows App SDK runtime: $0"
  nsExec::ExecToLog 'certutil.exe -f -addstore TrustedPeople "$INSTDIR\winai\AniTrack.cer"'
  Pop $0
  DetailPrint "AniTrack certificate: $0"
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-AppxPackage -Name AniTrack.WindowsAI | Remove-AppxPackage"'
  Pop $0
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  nsExec::ExecToLog 'certutil.exe -delstore TrustedPeople "AniTrack"'
  Pop $0
!macroend
