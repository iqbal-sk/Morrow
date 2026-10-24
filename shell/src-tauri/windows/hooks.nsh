; Morrow's additions to Tauri's NSIS installer (bundle.windows.nsis.installerHooks).

; The helper folder is replaced whole: an update would otherwise leave behind what an older version had there and
; this one doesn't (another ffmpeg's DLLs).
!macro NSIS_HOOK_PREINSTALL
  ${If} $INSTDIR != ""
    RMDir /r "$INSTDIR\helper"
  ${EndIf}
!macroend

; "Delete the application data" also takes Morrow's model (865 MB) and its index: the app keeps them in
; %LOCALAPPDATA%\Morrow, not in the data folders named after its identifier, which Tauri deletes. Never on an update.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    RMDir /r "$LOCALAPPDATA\Morrow\Models"
    RMDir /r "$LOCALAPPDATA\Morrow\index"
    RMDir "$LOCALAPPDATA\Morrow"
  ${EndIf}
!macroend
