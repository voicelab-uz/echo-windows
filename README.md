# VoiceLab Echo for Windows

The active Windows application is the native WinUI 3 project in `VoiceLab.WinUI3/`. Open `VoiceLabEcho.sln` in Visual Studio, or use `BUILD_AND_RUN.bat` to publish and start the x64 build. The older WPF solution is retained as `VoiceLabEcho.LegacyWpf.sln` for reference; its `VoiceLabEcho.App.exe` is not the current application.

## Build and run

Use the .NET 8 SDK on Windows:

```powershell
dotnet publish VoiceLab.WinUI3/VoiceLab.App/VoiceLab.App.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained true -p:WindowsAppSDKSelfContained=true -p:PublishSingleFile=false -o artifacts/VoiceLab-Echo-win-x64
./artifacts/VoiceLab-Echo-win-x64/VoiceLab.Echo.exe
```

Keep all published files beside `VoiceLab.Echo.exe`. The build requires microphone access and an internet connection for account sign-in and transcription. The default global dictation shortcut is Win+Alt+Space; choose another in Settings if Windows or another app has claimed it.

The app includes onboarding, browser sign-in, microphone capture, account transcription, device and account History, an always-on-top recording control, clipboard insertion, Home, Statistics, Notes, Vocabulary, Snippets, audio Upload, notifications, theme settings, and tray behavior. The current source and API details are in [the WinUI README](VoiceLab.WinUI3/README.md). The [release verification checklist](VoiceLab.WinUI3/RELEASE_VERIFICATION.md) identifies what still needs interactive testing.

## Current verification state

The WinUI application and smoke-test projects compile. This PC has Windows 11 Smart App Control in enforcement mode. It blocks the newly built unsigned executable and test DLLs before they start, so the latest source has **not** passed an end-to-end runtime test here. Smart App Control has no per-app exception: interactive testing requires a build signed by a trusted code-signing provider, a separate Windows environment that permits development builds, or a decision by the PC owner to change Smart App Control in Windows Security. Windows auto-update also needs a signed Windows release channel; the Mac Sparkle feed cannot update this app.
