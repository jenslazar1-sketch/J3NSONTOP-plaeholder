; Inno Setup 6 script for J3NSONTOP Multitool (Windows x64).
;
; Normally compiled by scripts\build_windows.ps1, which passes:
;   ISCC.exe /DAppVersion=1.0.0 /DAppNumericVersion=1.0.0.1
;            /DBundleDir=<absolute path of the release bundle>
;            /DOutputDir=<dist> /DOutputBaseFilename=<name>
;            [/DSignToolName=j3sign "/Sj3sign=<signtool command> $f"]
;
; The installer copies the complete release bundle (exe, flutter_windows.dll,
; plugin DLLs, MSVC runtime DLLs, data\) into {app}. User data is NOT stored in
; {app}: the app keeps it in %APPDATA%\J3NSONTOP\J3NSONTOP Multitool, which the
; uninstaller intentionally leaves in place.

#ifndef AppVersion
  #error Define AppVersion, e.g. ISCC /DAppVersion=1.0.0 j3nsontop_multitool.iss
#endif
#ifndef AppNumericVersion
  #define AppNumericVersion AppVersion + ".0"
#endif
#ifndef BundleDir
  #define BundleDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "J3NSONTOP-Multitool-" + AppVersion + "-windows-x64-setup"
#endif

#define AppName "J3NSONTOP Multitool"
#define AppFullName "J3NSONTOP BIGGEST MULTITOOL MADE"
#define AppPublisher "J3NSONTOP"
#define AppExeName "j3nsontop_multitool.exe"
; Never change the AppId: Windows uses it to recognise upgrades and the
; uninstall entry ({FFBDD466-85D3-4DD4-8AFD-4D7140A91A95}_is1).
; "{{" escapes the opening brace in [Setup], so AppId becomes {GUID}.
#define AppId "{{FFBDD466-85D3-4DD4-8AFD-4D7140A91A95}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppCopyright=Copyright (C) 2026 J3NSONTOP
AppComments={#AppFullName}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
; Per-machine install by default; the user may choose a per-user install
; (no admin rights needed) in the first wizard page.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppNumericVersion}
VersionInfoProductVersion={#AppNumericVersion}
VersionInfoTextVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoCopyright=Copyright (C) 2026 J3NSONTOP
#ifdef SignToolName
; Signs Setup.exe and the uninstaller with the sign tool passed via /S.
SignTool={#SignToolName}
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "{#AppFullName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Comment: "{#AppFullName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
