#ifndef PackageDir
  #error PackageDir must point to the self-contained publish directory.
#endif
#ifndef InstallerOutputDir
  #define InstallerOutputDir "..\..\artifacts"
#endif

[Setup]
AppId={{9DB3AAB1-27AE-4376-A3EE-735D26762A82}
AppName=VOICE4LAB ECHO
AppVersion=1.0.0
AppPublisher=VoiceLab
DefaultDirName={localappdata}\Programs\VoiceLab Echo
DefaultGroupName=VoiceLab Echo
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#InstallerOutputDir}
OutputBaseFilename=VoiceLab-Echo-Setup-x64
SetupIconFile={#PackageDir}\Assets\voicelab.ico
UninstallDisplayIcon={app}\VoiceLab.Echo.exe
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\VoiceLab.Echo.WinUI3
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Excludes: "*.pdb,START-HERE.txt,RELEASE_VERIFICATION.md"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\VOICE4LAB ECHO"; Filename: "{app}\VoiceLab.Echo.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\VOICE4LAB ECHO"; Filename: "{app}\VoiceLab.Echo.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\VoiceLab.Echo.exe"; Description: "Open VOICE4LAB ECHO"; Flags: nowait postinstall skipifsilent
