# JWL-Assistant
A lightweight yet powerful tool to auto-toggle your Zoom camera and control OBS functions and an OSC-based sound mixer.
JWL-Assistant works only when used with JW Library, published by the Watch Tower Bible and Tract Society of Pennsylvania. It is an independent project and is not affiliated with or endorsed by them.

<img width="474" alt="image" src="https://github.com/user-attachments/assets/b4cbb42e-ff53-4181-953c-d0f46ee94dba" />

JWL Assistant is a Windows tool that helps automate live meeting production with JW Library, OBS and Zoom. It combines scene control, OCR-based switching, Zoom meeting helpers, audio utilities, and quick operator actions in one interface to reduce manual steps during meetings. The goal is simple: make transitions smoother, setup faster, and operation more reliable for congregation AV workflows.

JWL Assistant - First Run Guide
Version: v6.1.8 and later

For Download : https://github.com/mvpapen/JWL-Assistant/releases/latest

What you need installed
- OBS Studio (with WebSocket enabled)
- Zoom desktop client
- Tesseract OCR ( will be installed if not present)
- JWLibrary and Play Video on 2 display= ON ( will not work without)
Before first launch
1. Start OBS Studio.
2. In OBS, verify WebSocket server is enabled.
3. Verify OBS connection settings in app Settings:
   - Host: 127.0.0.1
   - Port: 4456 (or match OBS entry)
   - Password: match OBS (or leave empty in both places)
4. Verify Tesseract path in app Settings.
   Typical path: C:\Program Files\Tesseract-OCR\tesseract.exe
5. Set Zoom Join Meeting ID and Display Name in app Settings.

First-run quick test
1. Launch JWL+OBS Assistant.
2. Confirm OBS status changes from waiting to online.
3. Test scene switch buttons.
4. Test Join Zoom button.
5. Confirm OCR status toggles ON/OFF when content is visible.
6. Enable HotKeys in Zoom for Canera , Mic and Mute all

If something does not work
- OBS connect failed:
  - Ensure OBS is open
  - Ensure WebSocket is enabled
  - Ensure port/password match Settings
- Zoom join failed:
  - Confirm Zoom desktop app is installed
  - Confirm meeting ID is valid
- OCR not working:
  - Recheck Tesseract path
  - Re-select OCR ROI in Settings
  - 
OSC Mixer UI for  Behringer XAir 18

 <img width="497"  alt="image" src="https://github.com/user-attachments/assets/3535700d-5023-4c4d-966d-728e389039e5" />
  
Main features
- Easier Mixer Layout customized for Meeting Use.(you still need original XAir Edit app do setup)
- Auto scan for Mixer IP
- You can connect any snapshot with any saved PTZ scene.
- 8 Snapshot presets.(Snapshot is a copy of a customised Mixer Layout)
- Auto Duck function when Music plays , and when Reader reads . Build in Limiter
- While there are many customized auto mix function you can  manualy overide anytime.  


Windows security note
- Unsigned EXE files can show SmartScreen warnings on some PCs.
- If prompted, use More info -> Run anyway only if you trust this file source.

Support info to include in bug reports
- App version
- Windows version
- OBS version
- Zoom version
- Screenshot or copied log lines around the failure

License and third-party software
- This repository is licensed under the custom JWL-Assistant license in LICENSE.
- The app is provided as-is, without warranty, and the author is not liable for damages arising from its use, to the extent allowed by law.
- If someone redistributes a modified version, they must clearly mark the changes, provide the modified source to recipients, and send a copy of those changes back through the official project repository.
- Tesseract OCR is a separate upstream project and remains licensed under the Apache License 2.0.
- The installer may download Tesseract with permission if it is not already installed. Credit for Tesseract belongs to its original authors and maintainers.
- See LICENSE for the project license and THIRD-PARTY-NOTICES.txt for third-party software details.
