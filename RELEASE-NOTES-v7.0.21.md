# JWL Assistant v7.0.21

Upgrade from any earlier version. Download **JWL-Assistant-Setup-7.0.21.exe** below and run it (your settings are kept).
This version includes everything from v7.0.20 and earlier.

## New

### 🌐 Web Presenter - show a website on your projector/TV monitor
A new globe button (right of the Hand Alert button) shows any website on a monitor of your choice - for demonstrating jw.org, playing a video from the site, or walking the congregation through a web page.

**How it works:**
1. Click **🌐**, pick the monitor to mirror to (remembered), type the website address (default: jw.org) and click **Open Website** (or press Enter).
2. The site opens in a normal **setup window on your main monitor** - nothing shows on the projector yet. Navigate to the right spot there (links, scrolling, Back / Forward / Refresh / Home in the 🌐 menu).
3. Click **▶ Start Mirroring** (green button next to 🌐, or in the menu). The same page appears full screen on the selected monitor and **follows the setup window**: page changes, scrolling, clicks, video play / pause / seeking (also players inside embedded frames) and a video's own fullscreen button.
4. Click **■ Stop Mirroring** when done - the setup window stays open for the next item. **Close Web Presenter** (menu) ends everything.

**Details:**
- The mirror sits **above JW Library's year text** the same way Toggle Zoom does, and simply closes again - JW Library and the JWL Media Fix are never touched.
- **OBS:** Start Mirroring switches OBS to your **Media scene** (same switch as the Media button) and Stop Mirroring returns to the previous scene. A scene you picked yourself in the meantime is left alone. Turn this off with the menu checkbox "Switch OBS to Media scene while mirroring". No OBS scenes or sources are created or changed.
- The mirror **hides the website's top menu bar and the scrollbar** for a clean presentation (menu checkbox "Hide the website's top menu bar on the mirror", on by default) - the setup window still shows the whole page.
- **− / + zoom** under the Start Mirroring button enlarges the website (25%-500%) on the setup window and the mirror together - for pages that look small with black bars on the sides.
- **Cursor button** (next to − / +, turns green when active): your mouse pointer shows on the mirror as a **large blue ring** that follows the mouse over the setup window - for pointing out where to go or drawing attention to something.
- While mirroring the setup window is **muted**, so sound only comes from the mirror (your normal OBS/mixer path).
- If the mirror monitor is unplugged, mirroring stops by itself and the setup window stays; pick another monitor and start again.
- The 🌐 button is grey when closed, amber while a website is open, green while mirroring.

**Requirements:** the Microsoft Edge WebView2 Runtime (already part of Windows 11 and included with Microsoft Edge). The small WebView2 wrapper (3 DLLs) is included in this setup; a portable copy of the app downloads it once into `%APPDATA%\JWL-OBS-Assistant\webview2` instead.

### From the unreleased v7.0.20
- **Auto Frame:** when the AF button is dimmed, hovering (or clicking) now tells you why, for example "OBS needs to be live".
- **Settings > OnlyT control:** a red note with a picture explains that the OnlyT window must be big enough to show the Meeting part selector.

## Notes
- The mirror recognises standard page headers and menus; on an unusual website it may hide too little or too much of the top bar - untick "Hide the website's top menu bar on the mirror" in the 🌐 menu then.
- Typing into text boxes and mouse-hover menus are not copied to the mirror; do those in the setup window before you start mirroring, or use the blue ring to point instead.
- If your Media scene captures JW Library with a **Window Capture** (instead of a Display Capture of the monitor), add a Window Capture of the window titled "JWL Web Presenter" to that scene once.
