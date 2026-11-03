# VoiceLab Echo: native Windows application

The supported Windows application uses .NET 8 and WinUI 3. Open the repository-root `VoiceLabEcho.sln`. The retired WPF projects and old progress reports have been removed from the current tree; committed versions remain in Git history.

## Source layout

| Directory | Purpose |
| --- | --- |
| `VoiceLab.App/Views` | Workspace, onboarding, and settings pages |
| `VoiceLab.App/Services` | Recording coordination, floating control, clipboard feedback, tray, and startup |
| `VoiceLab.App/Styles` | App and onboarding themes |
| `VoiceLab.Core` | Shared Windows domain models |
| `VoiceLab.Infrastructure/Services` | Authentication, account APIs, and focused local services |
| `VoiceLab.Infrastructure/Models` | Local storage and service data models; existing namespaces are preserved |
| `VoiceLab.Infrastructure/Storage` | Account-scoped encrypted persistence and BOM-compatible migration |
| `VoiceLab.Infrastructure/Audio` and `Hotkeys` | Microphone capture and Windows shortcut handling |
| `VoiceLab.SmokeTests` | Executable service regression checks |
| `installer` | Inno Setup recipe for a single installer EXE |

## Build and run

See [build instructions](../BUILD_INSTRUCTIONS.md) for prerequisites, Visual Studio setup, publishing, and installer generation.

```powershell
dotnet build VoiceLabEcho.sln -c Release -p:Platform=x64
dotnet run --project VoiceLab.WinUI3/VoiceLab.SmokeTests/VoiceLab.SmokeTests.csproj -c Release
```

Run these commands from the repository root. `BUILD_AND_RUN.bat` publishes and opens the WinUI application. A portable EXE must remain beside its runtime, DLLs, resources, and assets.

## Current behavior

The default shortcut is Win+Alt+Space: press once to record and again to finish. Optional hold and automatic activation modes remain in Settings. The global shortcut also starts the required onboarding voice practice. Practice pages have generated XAML metadata so Frame navigation can activate them safely.

History merges device and account records by server ID. Account transcript deletion is not supported by the desktop API, so those rows do not offer Delete. Clear local copies removes device copies while retaining the account view. Copy buttons confirm success inline. Notes autosaves, syncs account changes, and preserves conflicting edits as copies. Vocabulary and Snippets share a tabbed page.

User data and settings are protected with Windows DPAPI under `%LOCALAPPDATA%\VoiceLab\Echo`, with account separation. The rotating refresh credential is stored in Windows Credential Vault. UTF-8 BOM files from earlier previews migrate after a successful read. Assets include their applicable font and lexicon notices.

Desktop authentication, STT upload, account History, Notes, notifications, and usage attribution use the VoiceLab desktop API contracts. Failed dictation retains audio for a same-session retry. Recording is limited to ten minutes; file uploads support cancellation. See the code and acceptance checklist for exact edge cases and limits.

## Verification and release limits

Release builds and the service smoke tests pass. Published startup and per-user installer installation/startup have been checked on the development PC. Selected interactive checks covered onboarding shortcut navigation, tab switching, History layout, and Copy feedback; this is not a complete end-to-end acceptance pass.

Follow [RELEASE_VERIFICATION.md](RELEASE_VERIFICATION.md) for remaining checks. Packages are unsigned unless signed through a separate release process. Windows policies may block unsigned builds. Windows auto-update and complete interface localization remain unfinished.

All runtime assets required by the Windows app are bundled in its source projects. Keep the included font and lexicon licenses and provenance notices when distributing the app.
