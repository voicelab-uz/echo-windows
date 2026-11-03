# VoiceLab Echo for Windows

The Mac reference source and porting guidance are in [MacApp](MacApp/), [AGENTS.md](AGENTS.md), and [MAC_TO_WINDOWS.md](MAC_TO_WINDOWS.md).

The Windows application is the native WinUI 3 project in `VoiceLab.WinUI3/`. Open `VoiceLabEcho.sln` in Visual Studio, or use `BUILD_AND_RUN.bat` to publish and start the x64 build. The retired WPF projects and old status reports have been removed from the current tree; committed versions remain in Git history.

## Build and run

Use the .NET 8 SDK on Windows:

```powershell
dotnet publish VoiceLab.WinUI3/VoiceLab.App/VoiceLab.App.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true -p:WindowsAppSDKSelfContained=true -p:PublishSingleFile=false -o artifacts/VoiceLab-Echo-win-x64
./artifacts/VoiceLab-Echo-win-x64/VoiceLab.Echo.exe
```

Keep all published files beside `VoiceLab.Echo.exe`. The build requires microphone access and an internet connection for account sign-in and transcription. The default global dictation shortcut is Win+Alt+Space; choose another in Settings if Windows or another app has claimed it.

The app includes onboarding, browser sign-in, microphone capture, account transcription, device and account History, an always-on-top recording control, clipboard insertion, Home, Statistics, Notes, Vocabulary, Snippets, audio Upload, notifications, theme settings, and tray behavior. The current source and API details are in [the WinUI README](VoiceLab.WinUI3/README.md). The [release verification checklist](VoiceLab.WinUI3/RELEASE_VERIFICATION.md) identifies what still needs interactive testing.

## Current verification state

The WinUI application builds with zero warnings and errors, and the service smoke tests pass. On November 3, 2026, the development PC owner authorized disabling Smart App Control; the published app and the per-user installer were then launched successfully. Runtime checks covered onboarding shortcut navigation, Vocabulary/Snippets tab switching, History layout, and inline Copy confirmation. A retained dictation was recovered into encrypted History after fixing UTF-8 BOM migration. The full interactive acceptance checklist still requires completion. Unsigned builds may be blocked on other PCs; Windows auto-update also requires a signed Windows release channel.

## Installer

After publishing, use Inno Setup 6 to build a single installer EXE:

```powershell
ISCC.exe /DPackageDir="C:\path\to\published-app" /DInstallerOutputDir="C:\path\to\output" VoiceLab.WinUI3/installer/VoiceLab-Echo.iss
```

The installer includes the published runtime and assets, a Start menu shortcut, and an uninstaller. Signing remains a separate release step.
