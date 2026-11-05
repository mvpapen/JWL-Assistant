NOTE (2026-10-24): These files are NOT loaded by the main app.

"JWL+OBS Assistant v6.1.16c AppAudit.ps1" is fully self-contained and does
NOT dot-source anything from this folder. It has its own separate inline
copies of every function that used to live here (Log, Import-Settings,
Save-Settings, Enable-DarkMode, Register-ThemeForNewControls,
Test-ForAppUpdate, Set-ThemeRecursive, etc.).

This folder appears to be leftover from an earlier, abandoned attempt to
modularize the app (see dist\JWL+OBS Assistant v6.1.12VLC4
Modularization1.ps1). During an audit/remediation pass, several fixes were
mistakenly applied only to these files before this disconnect was
discovered - those fixes had zero effect on the running app. They have
since been re-applied directly inside the main script's own inline
functions, where they actually take effect.

This folder is kept only as a historical reference / in case real
modularization is revisited later. Do NOT edit these files expecting any
change to affect the running app - edit the main script directly instead.
