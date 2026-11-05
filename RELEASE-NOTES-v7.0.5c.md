# JWL Assistant v7.0.5c

Urgent fix for v7.0.5 and v7.0.5b (the installed EXE could not be closed). Includes everything from v7.0.5b.

## Fixes
- **App restarted itself every time it was closed** (installed EXE only). The close-time safety watchdog was started with the app's own EXE instead of PowerShell, so every exit launched a new copy. It now always uses a real PowerShell host.
- Everything in v7.0.5b: ROI warning always visible, V-Cam state picked up on connect, XR Mixer matches the app height.

## Files in this release
- `JWL-Assistant-Setup-7.0.5c.exe` - installer (installs per user, no admin rights needed)
