# JWL Assistant v7.0.5

## New in the 7.x line
- **New user interface** (WPF) with symbol-only buttons (no text, language independent), Small / Medium / Large sizes, light and dark theme, a large live camera preview with an on-screen clock, and a status bar (OBS, update status, next meeting).
- **Auto Frame (AF)** on the live preview: crosshair cursor inside the ROI, click to centre the camera, and a "Confirm ROI" panel that stays open while you set the ROI.
- **Auto Hand Alert**: watches the Zoom participants list and shows the hand overlay on the chosen monitor when someone raises a hand (red "A" dot on the hand button).
- **Stop Auto-Admit** button in the Auto-Admit list dialog.

## New in 7.0.5
- **Zoom health warning**: an orange "⚠ Zoom" in the status bar when Zoom answers very slowly or its mic status keeps flipping (restarting Zoom usually fixes it).
- **Restart during a meeting**: if the app starts between a scheduled start time and start + 105 minutes, background music does not auto-start, and Auto Toggle starts again by itself (when "auto-start Auto Toggle" is enabled).
- **Faster hand detection**: the participants list is remembered, so repeat scans take tens of milliseconds instead of seconds.
- **Camera preview recovers by itself** when OBS (or its virtual camera) starts after the app.
- **V-Cam button and scene changes made inside OBS** are now picked up within about 2 seconds.
- **OCR**: a slow Zoom no longer causes false "tesseract timed out" results or flips the JWL display state to OFF.
- **Stability**: global error handlers, non-blocking shutdown (the app closes quickly), Settings opens in about a second, OBS connection recovers from a dead socket.
- The installer now also ships the DirectShow plugin needed for the live camera preview (`VlcExtraPlugins`) and the offline Help pages.

## Requirements
- Windows 10/11 (64-bit)
- OBS Studio with WebSocket enabled, Zoom desktop client, JW Library with "Play Video on Second Display"
- Tesseract OCR (the installer offers to install it with winget)

## Files in this release
- `JWL-Assistant-Setup-7.0.5.exe` - installer (installs per user, no admin rights needed)
