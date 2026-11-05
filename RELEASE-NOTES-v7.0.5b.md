# JWL Assistant v7.0.5b

Bug-fix release on top of v7.0.5.

## Fixes
- **Start Auto Toggle without a usable ROI** no longer looks like a freeze. The warning is now always shown on top of the new window, and it also catches a saved ROI that lies outside every connected monitor (for example after a display change).
- **V-Cam button** no longer keeps flashing red when OBS is started with the Virtual Camera already on: the real state is read on connect, re-checked while unknown, re-synced periodically and before each click.
- **XR Mixer panel** now matches the height and top edge of the visible app window in the installed EXE as well.
- The Zoom mic/camera warning shown when Auto Toggle starts is also always visible.

## Files in this release
- `JWL-Assistant-Setup-7.0.5b.exe` - installer (installs per user, no admin rights needed)
