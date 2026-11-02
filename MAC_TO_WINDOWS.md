# Echo for Windows: porting the Mac app

The Mac app is the **source of truth** for how Echo looks, moves and behaves. Its complete source
is copied into this repo at **[`MacApp/`](MacApp/)** (read-only, see `MacApp/SNAPSHOT.md` for the
commit). The Windows app (.NET 8, WPF) must reproduce it screen for screen. Change only what
Windows forces you to change (see §5).

| Read this | For |
|---|---|
| `DesignHandoff/HANDOFF.md` | The spec: brand, layout, every screen, onboarding, shortcuts, API |
| `DesignHandoff/` assets | Icons, colours, fonts, copy, localization, ready for Windows |
| `MacApp/` | The real code, for every detail the spec does not state |
| This file | How to read the Swift code and where each piece goes on Windows |

---

## 1. How to port a screen

Do one screen at a time. Never design from memory or from a description alone.

1. **Find the Mac files** in the map (§3) and read them completely, including the helper views
   they use (`MacApp/Voicelab/Shared/*`).
2. **Write down every value** before writing XAML: sizes, paddings, corner radii, font sizes and
   weights, colours (and their light/dark variants), opacity, animation curve and duration, hover
   and pressed states, empty, loading and error states, and every string key.
3. **Build it in XAML** with those exact numbers. 1 SwiftUI point = 1 WPF device-independent pixel.
4. **Compare side by side** with the Mac app (or screenshots) in light and dark mode, at the
   smallest and a large window size. Fix differences before moving on.
5. **Check the states:** hover, pressed, keyboard focus, disabled, empty, long text, a right-to-left
   language (Arabic), *Animation effects* off.

If the spec and the code disagree, the code wins. If something can't be done on Windows, pick the
closest native equivalent and add a note to `DesignHandoff/HANDOFF.md` §9.

---

## 2. SwiftUI → WPF

| SwiftUI (Mac) | WPF (Windows) |
|---|---|
| `struct X: View { var body }` | `UserControl` (XAML) + ViewModel |
| `@Observable` model, `@State`, `@Binding` | `INotifyPropertyChanged` ViewModel (CommunityToolkit.Mvvm `[ObservableProperty]`), `TwoWay` bindings |
| `@Environment(...)` | DI-injected services / `DynamicResource` |
| `VStack` / `HStack` / `ZStack` | `StackPanel` (`Orientation`) / `Grid` with overlapping children |
| `spacing: 12` | `Margin` on children, or a spacing panel |
| `.padding(16)` | `Padding="16"` / `Margin="16"` |
| `.frame(width:height:)`, `maxWidth: .infinity` | `Width`/`Height`, `HorizontalAlignment="Stretch"` |
| `Spacer()` | `Grid` column `Width="*"` |
| `RoundedRectangle(cornerRadius: 12, style: .continuous)` | `Border CornerRadius="12"` (continuous corners can't be matched exactly; use the same radius) |
| `.stroke(..., lineWidth: 0.75)` | `BorderBrush` + `BorderThickness="0.75"` |
| `.foregroundStyle(.secondary)` | Secondary text brush from `Brand/colors.json` |
| `Color.primary.opacity(0.08)` | Ink colour with alpha 0x14 (8 %) |
| `Design.tint` / accent | One `DynamicResource AccentBrush`, updated live when the accent changes |
| `.font(.system(size: 14, weight: .medium))` | `FontFamily="Segoe UI Variable" FontSize="14" FontWeight="Medium"` |
| `.monospacedDigit()` | `Typography.NumeralAlignment="Tabular"` |
| `ScrollView` / `LazyVStack` | `ScrollViewer` + `ItemsControl` with `VirtualizingStackPanel` |
| `List` / `ForEach` | `ItemsControl` / `ListBox` with a custom `ItemContainerStyle` (no default selection chrome) |
| `.onHover` | `IsMouseOver` triggers / `MouseEnter`/`MouseLeave` |
| `ButtonStyle` (`EchoButtonStyle`, etc.) | A `ControlTemplate` per style (replace the default WPF button chrome completely) |
| `.sheet`, `.popover` | In-window overlay `Grid` / `Popup` (keep it inside the window, like the Mac) |
| `.contextMenu` | `ContextMenu` with a custom template |
| `withAnimation(.spring(duration: 0.38, bounce: 0))` | `Storyboard` with `CubicEase`/`QuinticEase EaseOut`, same duration |
| `.transition(.opacity)`, `matchedGeometryEffect` | Opacity / `TranslateTransform` storyboards; animate one shared element |
| `Canvas`, `Path`, `Shape` | `Path`, `Geometry`, `DrawingVisual`, or Win2D/Composition |
| `TimelineView(.animation)` | `CompositionTarget.Rendering` (stop when hidden) |
| `Text("Uzbek key")` + `Localizable.xcstrings` | `DesignHandoff/Localization/strings.json`; keys are the Uzbek source text |
| `Task { await ... }` | `async`/`await`, `Dispatcher` for UI updates |
| `Codable` + `convertFromSnakeCase` | `System.Text.Json` with `JsonNamingPolicy.SnakeCaseLower` |

---

## 3. File map

Paths below are inside `MacApp/`. The Windows locations follow this repo's projects:
`VoiceLabEcho.App` (UI), `VoiceLabEcho.Core` (models, rules), `VoiceLabEcho.Infrastructure`
(API, audio, storage, OS integration).

### App shell
| Mac | What it is | Windows |
|---|---|---|
| `Voicelab/VoicelabApp.swift` | App entry, menu-bar item, windows | `App.xaml(.cs)` |
| `Voicelab/App/AppModel.swift` | Composition root, session, navigation (`Destination`) | `MainViewModel`, DI setup |
| `Voicelab/App/RootView.swift` | Window: sidebar + content panel + toolbar (search, theme, bell) | `MainWindow.xaml` |
| `Voicelab/App/WorkspaceSidebarView.swift` | Sidebar, collapse, hover, selection | `Views/Shell/Sidebar.xaml` |
| `Voicelab/App/WorkspaceProfileView.swift` | Avatar + minutes ring + profile popover | `Views/Shell/ProfileButton.xaml` |
| `Voicelab/App/MenuBarView.swift`, `Shared/MenuBarIcon.swift` | Menu-bar menu and icon | Tray icon + menu (`DesignHandoff/Icons/tray-*`) |
| `Voicelab/App/LaunchSplashView.swift` | Launch logo reveal | `Views/Shell/Splash.xaml` |
| `Voicelab/App/Preferences.swift` | All user settings and defaults | `Core/Settings/Preferences.cs` (`%APPDATA%`) |
| `Voicelab/App/AppLocalization.swift` | Live language switching | `LocalizationService` |
| `Voicelab/App/LibraryModel.swift` | Notes, vocabulary, history store | `Core` + `Infrastructure/Storage` |

### Shared design system (port these first)
| Mac | Windows |
|---|---|
| `Voicelab/Shared/DesignSystem.swift`, `AppAccent.swift` | `Resources/Styles/Colors.xaml`, `Theme.xaml`, accent service |
| `Voicelab/Shared/EchoButtonStyle.swift` | `Resources/Styles/Buttons.xaml` |
| `Voicelab/Shared/WorkspaceControls.swift` | Motion constants (`WorkspaceMotion`), toolbar glass buttons |
| `Voicelab/Shared/WorkspacePanel.swift` | Rounded content panel style |
| `Voicelab/Shared/SettingsComponents.swift` | Settings section, group, row, hairline controls |
| `Voicelab/Shared/WorkspaceAssetIcon.swift`, `AppIcon.swift` | Icon control using `DesignHandoff/Icons/IconSet` |
| `Voicelab/Shared/UsageBalanceView.swift` | Minutes-left bar |
| `Voicelab/Services/AppearanceTransition.swift` | Circular theme reveal (snapshot old frame, clip with a growing ellipse) |
| `Voicelab/Assets.xcassets/*.colorset` | Already exported to `DesignHandoff/Brand/colors.json` |

### Screens
| Mac | Screen | Windows |
|---|---|---|
| `Features/History/HistoryView.swift`, `HistoryRow.swift`, `HistoryGroupRow.swift` | Home: greeting, overview card, recent activity | `Views/HistoryView.xaml` |
| `Features/Statistics/StatisticsView.swift`, `StatisticsHeatmap.swift`, `StatisticsModel.swift` | Statistics | `Views/StatisticsView.xaml` |
| `Features/Vocabulary/VocabularyView.swift`, `VocabularyEditor.swift` | Dictionary + Snippets | `Views/VocabularyView.xaml` |
| `Features/Notes/NotesView.swift` | Notes list drawer + editor | `Views/NotesView.xaml` |
| `Features/Notifications/*` | Toolbar bell popover | `Views/Shell/NotificationsPopup.xaml` |
| `Features/Settings/SettingsModal.swift`, `SettingsView.swift` | Floating Settings panel + pages | `Views/Settings/*` |
| `Features/Settings/SettingsAppearancePicker.swift` | Theme previews + accent palette | `Views/Settings/AppearancePicker.xaml` |
| `Features/Settings/ShortcutRecorder.swift` | Inline shortcut recorder | `Controls/ShortcutRecorder.xaml` |
| `Features/Settings/Changelog.swift` | Release notes | `Views/Settings/Changelog.xaml` |

### Dictation
| Mac | What it is | Windows |
|---|---|---|
| `Features/Dictation/DictationModel.swift` | Record → upload → transcript → insert | `DictationViewModel` / `DictationService` |
| `Features/Dictation/DictationIslandView.swift`, `IslandPresentation.swift`, `IslandGlassSurface.swift`, `CameraIslandShape.swift` | Floating recording pill | Top-centre, borderless, topmost, non-activating window (`WS_EX_NOACTIVATE`) |
| `Features/Dictation/DictationWaveform.swift` | 7-bar live waveform | Same bars driven by mic level |
| `Features/Dictation/IslandNoticeCenter.swift` | Short notices in the pill | Same |
| `Services/GlobalShortcut.swift`, `DictationShortcut.swift`, `DictationActivationMode.swift` | Global key, hold / tap / toggle | `Infrastructure/Services/KeyboardShortcutService.cs` (`WH_KEYBOARD_LL`) |
| `Services/MicrophoneCapture.swift`, `MicrophonePCMConverter.swift`, `PCMRecordingWriter.swift`, `AudioRecorder.swift` | 16 kHz mono capture → 16-bit WAV | `Infrastructure/Audio` (NAudio/WASAPI) |
| `Services/TextInsertionManager.swift`, `TextInsertion.swift`, `NativeTextInsertionEnvironment.swift`, `TextInsertionMethod.swift` | Insert into the focused app | UI Automation (`TextPattern`, `ValuePattern`) + `SendInput` / clipboard |

### Onboarding
| Mac | Windows |
|---|---|
| `Features/Onboarding/ProductionOnboardingView.swift`, `OnboardingModel.swift`, `OnboardingJourney.swift` | Onboarding window, step order, saved progress |
| `Features/Onboarding/Experience/Welcome*.swift` | Welcome + animated laptop demo |
| `Features/Onboarding/Experience/Permissions*.swift`, `PermissionSettingsDemo.swift` | Access step (draw Windows Settings instead) |
| `Features/Onboarding/Experience/Setup*.swift` | Microphone, shortcut + keyboard, alphabet |
| `Features/Onboarding/Experience/Questionnaire*.swift` | About you |
| `Features/Onboarding/Experience/TryIt*.swift` | Try it practice |
| `Features/Onboarding/Experience/Resources/*.json` | Copy (also in `DesignHandoff/Onboarding/Copy`) |
| `Features/Onboarding/OnboardingCompletionView.swift` | Finish animation into the main window |

Illustrations are drawn in code, never images: see `DesignHandoff/HANDOFF.md` §5.1.

### Core logic (port line by line, with the tests)
| Mac (`Packages/VoiceLabCore/Sources/VoiceLabCore/`) | Windows |
|---|---|
| `Domain/TextRules.swift` | Spacing, fit-to-context, replacements → `Core/Text/TextRules.cs` |
| `Domain/UzbekAlphabet*.swift`, `UzbekWordRecognition.swift`, `VocabularyRules.swift` | Uzbek Latin conversion, dictionary rules → `Core/Text` |
| `Domain/DictationStatistics.swift` (`StatisticsSummary`) | Statistics maths → `Core/Statistics` |
| `Domain/*` (others) | Models → `Core/Models` |
| `Networking/*` | API client → `Infrastructure/Api` |
| `Security/*` | Tokens, PKCE → `Infrastructure/Security` (Credential Manager / DPAPI) |
| `Persistence/*` | Local encrypted store → `Infrastructure/Storage` |
| `Packages/VoiceLabCore/Tests/*` | Port to `VoiceLabEcho.Tests` (xUnit). Same inputs, same expected outputs. |

### Not needed on Windows
`iOS/` (the iPhone app; only useful for the shared API), `EchoWakeHelper/` and `SharedSession/`
(macOS sleep and update helpers), Sparkle and `AppUpdate*` (use your own updater with the same
quiet UI), `Voicelab.xcodeproj`, `Configuration/*.entitlements`, Apple signing and notarization
docs in `docs/`.

---

## 4. Order of work

1. Design system: colours (light/dark), accent, fonts, buttons, panel, hairlines, motion constants.
2. Shell: window chrome, sidebar (collapse, hover, instant switching), toolbar, profile.
3. Home, Statistics, Vocabulary, Notes, Notifications.
4. Settings panel and all pages.
5. Dictation: shortcut, capture, pill, upload, text insertion (with ported `TextRules` tests).
6. Onboarding with code-drawn illustrations.
7. Tray icon, launch at login, updates, localization in all 16 languages.

---

## 5. Where Windows differs from the Mac

| Mac | Windows |
|---|---|
| `fn` key default | Right Alt default (HANDOFF §6) |
| Accessibility permission | Not needed; only microphone (Settings › Privacy & security › Microphone) |
| Notch "island" around the camera | Floating pill at the top centre of the active monitor |
| Menu-bar icon | Notification-area (tray) icon |
| Keychain | Windows Credential Manager / DPAPI |
| Login item | `HKCU\...\Run` or a startup task |
| System accent colour / Multicolour | `UISettings.GetColorValue(UIColorType.Accent)` |
| Liquid glass / vibrancy | Mica (Windows 11) with a solid fallback on Windows 10 |
| SF Symbols | Fluent icons only where the Mac uses an Apple symbol (e.g. Statistics) |
| ⌘ shortcuts | Ctrl equivalents (HANDOFF §6) |

## 6. Why WPF apps usually don't look like the Mac (avoid these)

- Default control templates: replace Button, TextBox, ScrollBar, ComboBox, ListBox, ToggleButton,
  ContextMenu and ToolTip templates. No default blue focus rectangles or selection highlights.
- Fonts: set `Segoe UI Variable` everywhere and `TextOptions.TextFormattingMode="Display"` for small
  text; use Manrope only in onboarding.
- Spacing: copy the Mac's numbers; don't use WPF default margins.
- Window: custom `WindowChrome`, rounded corners, no classic title bar.
- Scrollbars: thin, overlay style, inset from the panel edge.
- Motion: every hover/press/selection change animates with the Mac's duration; page switches are
  instant.
- Dark mode: every brush is a `DynamicResource`, so switching themes never needs a restart.
