How to build the EXE and the installer

1. Build the EXE (from the repository folder):
     .\Build-App.ps1 -Version 7.0.5
   Needs the ps2exe module (Install-Module ps2exe). Output: "JWL+OBS Assistant v7.0.5.exe" (uses Installer\jwl-assistant.ico).
2. Build the installer:
     .\Installer\Build-Installer.ps1
   Needs Inno Setup 6. Output: Installer\JWL-Assistant-Setup-7.0.5.exe
   (the version is set once, at the top of JWL-Assistant-Setup.iss: #define AppVer)
3. Upload the setup file to GitHub Releases:
     JWL-Assistant-Setup-7.0.5.exe

What users get
- Normal setup wizard with install location selection
- Optional desktop shortcut checkbox
- Start Menu shortcuts
- Uninstall entry in Windows Installed Apps
- Offers to install Tesseract OCR (winget) if it is missing
