; JWL Assistant installer (Inno Setup)

[Setup]
AppId={{A1E94FA8-4E9D-4C2F-8AA8-7F945E13E42A}
AppName=JWL Assistant
AppVersion=6.1.11
AppVerName=JWL Assistant 6.1.11
AppPublisher=mvpapen
AppPublisherURL=https://github.com/mvpapen/JWL-Assistant
DefaultDirName={localappdata}\Programs\JWL-Assistant
DefaultGroupName=JWL Assistant
SetupIconFile=..\Installer\jwl-assistant.ico
UninstallDisplayIcon={app}\JWL Assistant.exe
OutputDir=.
OutputBaseFilename=JWL-Assistant-Setup-v6.1.11
Compression=lzma
SolidCompression=yes
WizardStyle=modern
AlwaysShowDirOnReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "..\JWL+OBS Assistant v6.1.11.exe"; DestDir: "{app}"; DestName: "JWL Assistant.exe"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\JWL Assistant\JWL Assistant"; Filename: "{app}\JWL Assistant.exe"
Name: "{autodesktop}\JWL Assistant"; Filename: "{app}\JWL Assistant.exe"; Tasks: desktopicon
Name: "{autoprograms}\JWL Assistant\Uninstall JWL Assistant"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\JWL Assistant.exe"; Description: "Launch JWL Assistant"; Flags: nowait postinstall skipifsilent

[Code]
var
	IntroPage: TWizardPage;
	IntroText: TNewStaticText;

const
	TesseractUrl = 'https://github.com/UB-Mannheim/tesseract/wiki';

procedure InitializeWizard;
begin
	IntroPage := CreateCustomPage(
		wpWelcome,
		'Before You Install',
		'Please review these quick setup notes');

	IntroText := TNewStaticText.Create(IntroPage);
	IntroText.Parent := IntroPage.Surface;
	IntroText.Left := ScaleX(0);
	IntroText.Top := ScaleY(0);
	IntroText.Width := IntroPage.SurfaceWidth;
	IntroText.Height := IntroPage.SurfaceHeight;
	IntroText.WordWrap := True;
	IntroText.Caption :=
		'This installer will install JWL Assistant to:' + #13#10 +
		ExpandConstant('{localappdata}\Programs\JWL-Assistant') + #13#10 + #13#10 +
		'What this setup does:' + #13#10 +
		'1. Creates an app folder and copies files.' + #13#10 +
		'2. Adds Start Menu shortcuts.' + #13#10 +
		'3. Optionally creates a Desktop shortcut.' + #13#10 +
		'4. Adds an uninstall entry in Windows Installed Apps.' + #13#10 + #13#10 +
		'Tesseract OCR requirement:' + #13#10 +
		'- OCR scanning in JWL Assistant requires Tesseract OCR.' + #13#10 +
		'- If Tesseract is not found, setup can download and install it for you automatically.' + #13#10 + #13#10 +
		'Tip: Keep "Create a desktop shortcut" checked if you want easy access.';
end;

function IsTesseractInstalled(): Boolean;
begin
	Result :=
		FileExists(ExpandConstant('{pf}\Tesseract-OCR\tesseract.exe')) or
		FileExists(ExpandConstant('{pf32}\Tesseract-OCR\tesseract.exe')) or
		FileExists(ExpandConstant('{localappdata}\Programs\Tesseract-OCR\tesseract.exe'));
end;

function TryInstallTesseractWithWinget(): Boolean;
var
	ResultCode: Integer;
	Cmd: string;
begin
	Result := False;
	Cmd := '/C winget install --id UB-Mannheim.TesseractOCR -e --accept-package-agreements --accept-source-agreements';

	if Exec(ExpandConstant('{cmd}'), Cmd, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
	begin
		Result := (ResultCode = 0) and IsTesseractInstalled();
	end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
	Choice: Integer;
	ResultCode: Integer;
begin
	Result := True;

	if CurPageID = wpReady then
	begin
		if not IsTesseractInstalled() then
		begin
			Choice := MsgBox(
				'Tesseract OCR was not found on this PC.' + #13#10 + #13#10 +
				'JWL Assistant OCR features require Tesseract.' + #13#10 +
				'Install Tesseract now automatically?' + #13#10 + #13#10 +
				'Yes = Install now (winget)' + #13#10 +
				'No = Continue without Tesseract' + #13#10 +
				'Cancel = Return to installer',
				mbConfirmation,
				MB_YESNOCANCEL
			);

			if Choice = IDYES then
			begin
				MsgBox(
					'The installer will now run winget to install Tesseract.' + #13#10 +
					'This may take up to a minute.',
					mbInformation,
					MB_OK
				);

				if TryInstallTesseractWithWinget() then
				begin
					MsgBox('Tesseract installed successfully.', mbInformation, MB_OK);
				end
				else
				begin
					Choice := MsgBox(
						'Automatic install did not complete.' + #13#10 +
						'Open the Tesseract download page now?',
						mbConfirmation,
						MB_YESNO
					);
					if Choice = IDYES then
					begin
						ShellExec('open', TesseractUrl, '', '', SW_SHOWNORMAL, ewNoWait, ResultCode);
					end;
				end;
			end
			else if Choice = IDCANCEL then
			begin
				Result := False;
			end;
		end;
	end;
end;
