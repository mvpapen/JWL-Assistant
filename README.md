# JWL-Assistant
A powerful tool that automatically toggles your Zoom camera and controls OBS functions and OSC-based audio mixers.
JWL-Assistant works only when used with JW Library, published by the Watch Tower Bible and Tract Society of Pennsylvania. It is an independent project and is not affiliated with or endorsed by them.

<img width="534" height="580" alt="image" src="https://github.com/user-attachments/assets/afc4144f-903d-4ca0-bc40-bd16aa4b13a6" />


JWL Assistant is a Windows tool that helps automate live meeting production with JW Library, OBS and Zoom. It combines scene control, OCR-based switching, Zoom meeting helpers, audio utilities, and quick operator actions in one interface to reduce manual steps during meetings. The goal is simple: make transitions smoother, setup faster, and operation more reliable for congregation AV workflows.

JWL Assistant - First Run Guide
Version: v7.0.14 ( later versions  share the same first-run steps)

For Download : https://github.com/mvpapen/JWL-Assistant/releases/latest

For Video tutorials open the file : Video-tutorials.md

What you need installed
- OBS Studio (with WebSocket enabled)Use only v32.1.2 for now (newer version have PTZ control problems)
 
   -Zoom Desktop Client

   -Tesseract OCR (installed automatically if not already present)

   -JW Library with "Play Video on Second Display" enabled (required)
before first launch
   - VLC Library will also auto install if you use new UI.

1. Start OBS Studio.
2. In OBS, verify WebSocket server is enabled.
3. Verify OBS connection settings in app Settings:
   - Host: 127.0.0.1
   - Port: 4456 (or match OBS entry)
   - Password: match OBS (or leave empty in both places)
   - Add a video source (a PTZ camera is recommended). USB cameras are easiest to set up. For PTZ control, install the           latest OBS PTZ plugin with UVC support for USB PTZ.
   - add minmun 2 scenes; 1.Speaker + 2. Media (PTZ add Table , Demo, Speaker and Reader and so on.
   - for Media Scene use : Display capture or use capture card as Video source
4. Verify Tesseract path in App Settings.
   Typical path: C:\Program Files\Tesseract-OCR\tesseract.exe
5. Set Zoom Join Meeting ID and Display Name in App Settings.

First-run quick test (watch how it works video 4 min)  https://go.screenpal.com/watch/cO1iYRnuFmo
1. Launch JWL+OBS Assistant.
2. Confirm OBS status changes from .... Waiting to Online.
3. Test scene switch buttons.
4. Test Join Zoom button.
5. Confirm OCR status toggles ON/OFF when content is visible.
6. Enable HotKeys in Zoom for Canera , Mic and Mute all

Web Presenter (🌐 button, right of the Hand Alert button)
1. Click 🌐, pick the monitor to mirror to (listed as Windows "Display 1, 2, 3 ..."; remembered), type the website address on the single line (default: jw.org) and click Open Website (or press Enter).
2. The website opens in a normal "setup" window on your MAIN monitor, nothing is shown on the projector yet. Navigate to the right spot there (links, scrolling, Back / Forward / Refresh / Home in the 🌐 menu, or type another address and press Enter).
3. Click Start Mirroring (in the 🌐 menu, or the green button that appears right of 🌐 while a website is open). The same page is now shown on the selected monitor and follows the setup window: page changes and scrolling are copied. Click the button again (Stop Mirroring) to stop; the setup window stays open. Close Web Presenter in the menu ends everything.
4. The 🌐 button is amber while a website is open and green while mirroring. Fullscreen presentation (menu) can be switched off to get a normal window on the monitor.
- Zoom: while a website is open, a small − / + pill appears under the Start Mirroring button. It zooms the website in or out (25% to 500%) in the setup window and on the mirror together, so a page that looks small with black bars on the projector can be enlarged. It starts at 100% each time the Web Presenter is opened.
- The mirror shows no scrollbars and hides the website's top menu bar (the logo/header bar and the menu bar flush with the top of the page), also while scrolled; the setup window still shows the whole page. This is a checkbox in the 🌐 menu ("Hide the website's top menu bar on the mirror", on by default); it recognises standard page headers and menus, so on an unusual site it may hide too little or too much - untick it then.
- Pointer: a small cursor button sits right of the zoom − / + (only while a website is open). Click it to show your mouse pointer on the mirror as a large blue ring that follows the mouse over the setup window (also inside embedded frames), to point out where to go or draw attention to something. Click it again to hide the ring. It switches off by itself when mirroring stops.
- The mirror copies the page address, scrolling, clicks, and video/audio play, pause and seeking (also for players inside embedded frames), plus a video's own fullscreen button. While mirroring, the setup window is muted so the sound only comes from the mirror. Not copied: typing in text boxes and mouse hover.
- The mirror window sits above JW Library's year text the same way Toggle Zoom does and is simply closed again by Stop Mirroring; JW Library and the JWL Media Fix are never touched.
- Needs the Microsoft Edge WebView2 Runtime (already included with Windows 11 and Microsoft Edge). Nothing else has to be installed:
  the small WebView2 wrapper (3 DLLs, about 1 MB) is downloaded once into %APPDATA%\JWL-OBS-Assistant\webview2, or copy a folder named "webview2" with
  Microsoft.Web.WebView2.Core.dll, Microsoft.Web.WebView2.WinForms.dll and WebView2Loader.dll next to the program for offline PCs.
- OBS: Start Mirroring switches OBS to the Media scene (the same switch as the Media button) and remembers the scene that was live; Stop Mirroring (or Close Web Presenter, or losing the monitor) puts OBS back on that scene. If you chose another scene yourself in the meantime, it is left alone; if the old scene no longer exists, the last saved / selected camera scene is used. Untick "Switch OBS to Media scene while mirroring" in the 🌐 menu to turn this off. No OBS scenes or sources are created or changed. If your Media scene uses a Display Capture of the monitor chosen here, the website
  appears there automatically (use the same monitor JW Library uses for "Play Video on Second Display" - the website simply covers it while mirroring).
  If the Media scene captures JW Library with a Window Capture, add a Window Capture source for the window titled "JWL Web Presenter"
  (the mirror window; the operator window is titled "JWL Web Presenter Setup ...") to your Media scene yourself.
- If the mirror monitor is unplugged, mirroring stops by itself and the setup window stays; choose another monitor and click Start Mirroring.

If something does not work
- OBS connect failed:
  - Ensure OBS is open
  - Ensure WebSocket is enabled
  - Ensure port/password match Settings
- Zoom join failed:
  - Confirm Zoom desktop app is installed
  - Confirm meeting ID and Name is valid
- OCR not working:
  - Recheck Tesseract path
  - Re-select the OCR region in Settings (best results are achieved with monitor scaling set to 100%).
  - 
OSC Mixer UI for  Behringer XAir 18 with USB, or XAir 16 no USB connection to PC= Analog only

 <img width="497"  alt="image" src="https://github.com/user-attachments/assets/3535700d-5023-4c4d-966d-728e389039e5" />
  
Main features
- Simplified mixer layout customized for meeting use.
- (The original X Air Edit application is still required for mixer configuration.)
- Auto scan for Mixer IP
- Link any mixer snapshot to any saved PTZ camera preset.
- 8 Snapshot presets.(Snapshot is a copy of a customised Mixer Layout)
- Automatic audio ducking when music plays or when the reader speaks.
- Includes a built-in limiter that can be enabled or disabled.
- While many automatic mixing functions are available, you can manually override them at any time.
- link for X-Aire-Edit dowload : https://cdn-media.empowertribe.com/7fc0f5e32e824e3f88934381f3bce54a/X-AIR-Edit_PC_1.8.1.zip
- for manual download ,open download page link: https://www.behringer.com/en/products/0605-AAD , than click Download Button to open page.


Windows security note
- Unsigned EXE files can show SmartScreen warnings on some PCs.
- If prompted, use More info -> Run anyway only if you trust this file source.

Support info to include in bug reports
- App version
- Windows version
- OBS version
- Zoom version
- Screenshot and/or copied log entries related to the issue.

License and third-party software
- This repository is licensed under the custom JWL-Assistant license in LICENSE.
- The app is provided as-is, without warranty, and the author is not liable for damages arising from its use, to the extent allowed by law.
- If someone redistributes a modified version, they must clearly mark the changes, provide the modified source to recipients, and send a copy of those changes back through the official project repository.
- Tesseract OCR is a separate upstream project and remains licensed under the Apache License 2.0.
- The installer may download Tesseract with permission if it is not already installed. Credit for Tesseract belongs to its original authors and maintainers.
- See LICENSE for the project license and THIRD-PARTY-NOTICES.txt for third-party software details.
