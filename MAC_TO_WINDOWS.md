# Mac reference and the current Windows app

Echo for Windows is a .NET 8 / WinUI 3 application in `VoiceLab.WinUI3/`. The root `VoiceLabEcho.sln` is the supported solution. The retired WPF implementation is no longer part of the current source tree.

The read-only [MacApp](MacApp/) snapshot supplies reference behavior, design values, and API contracts. Its provenance is in [MacApp/SNAPSHOT.md](MacApp/SNAPSHOT.md). Licensed handoff assets and specifications are in [DesignHandoff](DesignHandoff/).

## Workflow

1. Read [DesignHandoff/HANDOFF.md](DesignHandoff/HANDOFF.md).
2. Read the matching Swift source completely, including shared views and services.
3. Preserve API contracts, data semantics, and relevant regression cases when porting.
4. Use the established Windows styles and licensed assets. Follow explicit user requests where Windows behavior or layout differs.
5. Check light/dark themes, narrow layouts, keyboard use, loading/error states, and accessibility.

Do not edit `MacApp/` directly. Refresh the snapshot through `DesignHandoff/Tools/sync-mac-source.sh /path/to/echo`.

## Source map

Paths in the first column are relative to `MacApp/Voicelab/` unless otherwise stated.

| Mac source | Current Windows implementation |
| --- | --- |
| `Features/History/*` | `VoiceLab.App/Views/HomePage` and `HistoryPage` |
| `Features/Statistics/*` | `VoiceLab.App/Views/StatisticsPage`, statistics services |
| `Features/Vocabulary/*` | `DictionaryPage` tabs containing `VocabularyPage` and `SnippetsPage` |
| `Features/Notes/*` | `VoiceLab.App/Views/NotesPage`, local and account Notes services |
| `Features/Notifications/*` | Shell notification flyout and `AccountNotificationService` |
| `Features/Settings/*` | `VoiceLab.App/Views/SettingsPage` |
| `Features/Dictation/*` | `RecordingCoordinator` and `RecordingOverlayService` |
| `Features/Onboarding/*` | `OnboardingShellPage` and `Views/Onboarding/` |
| `Services/GlobalShortcut.swift` and activation-mode types | `VoiceLab.Infrastructure/Hotkeys/GlobalHotkeyService` |
| Microphone capture and PCM conversion services | `VoiceLab.Infrastructure/Audio/AudioCaptureService` |
| Text insertion services | `VoiceLab.App/Services/RecordingCoordinator` |
| `Packages/VoiceLabCore` (under `MacApp/`) | `VoiceLab.Core`, infrastructure services, and `VoiceLab.SmokeTests` |
| Shared design and workspace controls | `VoiceLab.App/Styles`, bundled fonts, SVG assets, and shared controls |

Windows paths in this table are relative to `VoiceLab.WinUI3/`. Page names omit `.xaml` and `.xaml.cs` suffixes.

## Native equivalents

| SwiftUI | WinUI 3 |
| --- | --- |
| VStack / HStack / ZStack | StackPanel / Grid |
| Observable state | Bindings, events, and services |
| ScrollView / List | ScrollViewer / ListView / ItemsControl |
| Sheets / popovers / menus | ContentDialog / Flyout / MenuFlyout |
| Theme colors | Theme resources and app palette brushes |
| Animation | Windows Composition and XAML visual states |
| Shortcuts / microphone / credentials | Windows hotkeys and hooks / NAudio / Credential Vault and DPAPI |

## Windows release limits

Windows uses its own installer and signing process. macOS Sparkle packages cannot update the WinUI app. Unsigned development builds may be blocked by Windows security policies. Do not change system security settings as part of ordinary building or installation.

See [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) and [RELEASE_VERIFICATION.md](VoiceLab.WinUI3/RELEASE_VERIFICATION.md). The smoke tests do not replace interactive microphone, browser sign-in, and insertion checks.
