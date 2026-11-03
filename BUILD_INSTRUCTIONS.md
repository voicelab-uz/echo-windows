# Build VoiceLab Echo for Windows

The supported application is the WinUI 3 project in `VoiceLab.WinUI3/`.

## Requirements

- Windows 10 version 2004 or later, or Windows 11, x64.
- .NET 8 SDK.
- Visual Studio with Windows application development tools for interactive debugging.

## Visual Studio

Open `VoiceLabEcho.sln`, set `VoiceLab.App` as the startup project, choose **Debug / x64**, and press **F5**.

## Command line

```powershell
dotnet restore VoiceLabEcho.sln -p:Platform=x64
dotnet build VoiceLabEcho.sln -c Release -p:Platform=x64 --no-restore
dotnet run --project VoiceLab.WinUI3/VoiceLab.SmokeTests/VoiceLab.SmokeTests.csproj -c Release
```

## Portable build

Run `BUILD_AND_RUN.bat`, or publish manually:

```powershell
dotnet publish VoiceLab.WinUI3/VoiceLab.App/VoiceLab.App.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true -p:WindowsAppSDKSelfContained=true -p:PublishSingleFile=false -o artifacts/VoiceLab-Echo-win-x64
```

Run `VoiceLab.Echo.exe` from that directory. Keep its DLLs, runtime, resources, and Assets folder together.

## Installer EXE

Install Inno Setup 6, then compile the installer against the published directory:

```powershell
ISCC.exe /DPackageDir="C:\path\to\published-app" /DInstallerOutputDir="C:\path\to\output" VoiceLab.WinUI3/installer/VoiceLab-Echo.iss
```

The result is `VoiceLab-Echo-Setup-x64.exe`. It installs per user and includes an uninstaller. Generated packages belong in ignored `artifacts/`; do not commit them. Code signing is a separate release requirement. Unsigned applications may be blocked by Windows security policies.

Use [RELEASE_VERIFICATION.md](VoiceLab.WinUI3/RELEASE_VERIFICATION.md) before distributing a release. A successful build does not verify microphone capture, sign-in, or text insertion end to end.
