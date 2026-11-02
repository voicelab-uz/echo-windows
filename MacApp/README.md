# Echo for macOS

Native SwiftUI implementation in the **Xcode-created `Voicelab.xcodeproj`**.
The project is the source of truth: no XcodeGen, Flutter, Electron, web view, or
third-party package is needed.

The shipped application is **Echo.app**. Its Dock icon and in-app artwork use the
provided `echo.png` (bundled as `EchoLogo`). Release builds reuse VoiceLab's
`uz.voicelab.desktop` bundle ID and publishing team while keeping the native app's
own Keychain service and library paths. Electron data migration and upgrade
validation are described in the [CDN release guide](docs/CDN_RELEASE.md).
The Xcode project/scheme and VoiceLab API names remain compatible with the
existing development and backend setup.

The iPhone app and keyboard extension are under [`iOS/`](iOS/README.md). Open
`iOS/VoiceInput.xcodeproj` to build Echo for iPhone; the macOS project above is
unchanged.

## Run

1. Open `Voicelab.xcodeproj`.
2. Select the **Voicelab** scheme and **My Mac**.
3. Run with **⌘R**. The existing development team and bundle identifier are retained.
4. Sign in through the browser, allow microphone access, and start a recording.
5. For insertion into another application, enable VoiceLab under System Settings
   → Privacy & Security → Accessibility.

Minimum deployment target: macOS 14. Swift language mode: 6.
The local `Packages/VoiceLabCore` dependency resolves without network downloads.

New developers: read [Apple team access](docs/APPLE_TEAM_ACCESS.md) first. The
current Individual membership cannot grant Xcode team signing access through an
App Store Connect invitation; the guide covers local signing and release access.

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/test-onboarding-observation.sh
./scripts/test-browser-authentication.sh
./scripts/test-alphabet-preferences.sh
./scripts/test-notes-sync.sh
```

Build output: `build/Build/Products/Debug/Echo.app`.
The script uses the project's configured Apple Development signing identity, matching
Xcode Run so Keychain access stays tied to the same app identity. Distribution signing
and notarization use the separate [CDN release workflow](docs/CDN_RELEASE.md).

For a CDN release, configure `Configuration/release.env.local` from the checked-in
example, load its environment variables, and run:

```sh
./scripts/release.sh check
./scripts/release.sh all 2.0.0 1
```

The release driver archives, exports with Developer ID signing, notarizes, staples,
and verifies a ZIP before placing it with its checksum and metadata under `dist/`.
It supports separate `build`, `sign`, `notarize`, and `package` stages, including
resuming a notarization wait. CDN upload and interactive smoke testing are separate
steps. See the runbook for credentials, recovery, and required CDN configuration.
Run `./scripts/test-release.sh` for offline release-workflow regression checks.

In a restricted automation environment that cannot launch nested compiler sandboxes,
the validation commands are:

```sh
swift test --package-path Packages/VoiceLabCore --disable-sandbox
SWIFT_MACRO_SANDBOX_DISABLED=1 ./scripts/test-onboarding-observation.sh
xcodebuild -project Voicelab.xcodeproj -scheme Voicelab \
  -configuration Debug -derivedDataPath /private/tmp/voicelab-validation CODE_SIGNING_ALLOWED=NO \
  -IDEPackageSupportDisableManifestSandbox=YES \
  'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' build
```

This compiler flag is not saved in the Xcode project. The unsigned validation product
is for compilation only; use Xcode Run or the signed build script to launch the app.

The browser regression test uses a real loopback socket with a fake authorization
server response; it never launches the browser or signs in to an account. Run it
in a normal terminal. Environments that prohibit listening on local ports can run
`./scripts/test-browser-authentication.sh --parser-only`; this checks HTTP request
validation but does not verify socket delivery, cancellation or timeout.

## Code organization

```text
Voicelab/
  VoicelabApp.swift           App lifecycle, window, menu bar, commands
  ContentView.swift           Root view entry point
  App/                       Composition, session, preferences, library state
  Features/
    Onboarding/              15-step first-run flow, permissions, practice, profile sync
    Dictation/               Recording state machine and recording card
    History/                 Search and revision-aware transcript editing
    Notes/                   Local notes editor
    Vocabulary/              Vocabulary and explicit text replacements
    Settings/                Account, permissions and preferences
  Services/                  AVFoundation, AppKit, Network, Carbon, Accessibility
  Shared/                    Shared SwiftUI presentation components
Packages/VoiceLabCore/
  Sources/VoiceLabCore/
    Domain/                  Sendable value models and pure text rules
    Networking/              API contracts, HTTP transport, file-backed uploads
    Security/                PKCE and credential lifecycle
    Persistence/             Keychain and encrypted account storage
  Tests/VoiceLabCoreTests/    Offline contract, concurrency and storage tests
Configuration/               Entitlements
```

The core package has no SwiftUI or AppKit dependency. `DesktopServing`,
`HTTPTransport` and `SecretStore` are the test seams. UI models are explicitly
main-actor isolated; credential and file access are serialized by actors.

Views call feature models. Feature models call application services or core
protocols. `AppModel` constructs dependencies and coordinates account changes;
`DictationModel` owns recording lifecycle; `LibraryModel` owns editable state and
debounced persistence.

`MicrophoneTestModel` owns the live-test lifecycle and rejects stale callbacks after
navigation or device changes. `MicrophoneCapture` confines AVFoundation capture,
DSP and optional WAV writing to a dedicated serial queue; its Sendable callbacks
hop to the main actor before updating observable state. Capture requests the device's
native PCM; `MicrophonePCMConverter` maintains an `AVAudioConverter` for conversion
to mono 16 kHz rather than requiring hardware-side format conversion. Startup waits
for real audio buffers (including silence) and fails after five seconds without
data. A previous dictation capture is stopped before opening the next one.
`MicrophoneMeter` uses
Accelerate for a 256-point spectrum and six consecutive above-threshold frames.
`PCMRecordingWriter` streams dictation to disk; the onboarding test never creates
one. The offline regression harness covers lifecycle races and WAV output without
opening a microphone.

## Implemented native flows

### Desktop feature scope

The reference is the reachable UI in `../voicelab-desktop`, not every component
left in its source tree. The 2026-10-20 source audit found:

| Area | Electron entry point / behavior | Native status |
| --- | --- | --- |
| Home / history | `ControlPanelSidebar.tsx` → `HistoryView`: dated recordings, copy, edit, delete/clear, retry/discarded recordings, pagination | History, search, copy, editing and pagination; not full action parity |
| Vocabulary | Sidebar → `DictionaryView`: local word CRUD, language, text import/export and a separate snippets tab; network sync is disabled | Matching two-tab local workflow, word/snippet editing, language, import/export, duplicate handling and clear-dictionary confirmation |
| Notes | Sidebar → `PersonalNotesView`: notes, folders and meeting recording controls | Account-synced notes, pinning, editing and cursor-aware dictation (requires the new Notes backend); not cloud folders or meeting recording |
| Audio upload | `UploadAudioView` and its conditional route remain in source, but no reachable navigation sets `activeView` to `upload` | Standalone upload navigation, view and unused import action removed |
| Integrations | Opened through `onShowIntegrations`, not a primary sidebar item | Not implemented; no placeholder navigation |

The old `DictionaryService` throws for legacy endpoints. Local Vocabulary uses
`desktop-dictionary-*` IPC handlers and the desktop sync store, but a deeper audit
confirmed that `SyncService.canSync()` returns false and `voiceLabApiClient`'s
bootstrap/mutation/change methods all throw `DESKTOP_ENDPOINT_UNAVAILABLE`.
Do not mistake those IPC/storage hooks for working cloud synchronization.
The current cloud STT request sends audio and language, not dictionary hints.
Native Vocabulary therefore remains local and makes no claim to influence cloud
recognition. Snippets expand the returned transcript locally before insertion.
Keep future navigation tied to working, reachable reference features. Do not
present legacy routes or unfinished native services as working capabilities.

- PKCE browser authentication against the existing desktop API. A normal URL opens
  in the default browser's existing session. A temporary `127.0.0.1` listener on an
  OS-selected port receives the callback, avoiding conflicts with the Electron
  app's `voicelab://` handler. The exact redirect, state and PKCE verifier are
  checked; cancellation and expiration close the listener.
- A 15-step onboarding flow matching the desktop step order: welcome, sign-in,
  role, writing use cases, permissions, microphone test, shortcut verification,
  Uzbek alphabet, practice introduction, message/email/list practice,
  estimated time savings, style/appearance and completion.
- Access and refresh credentials stored together in Keychain, with shared refresh
  rotation. Relaunch reuses a still-valid access token; legacy refresh-only sessions
  migrate on their next rotation. Authentication cooldowns survive relaunch and
  are scoped to the server operation (authorize/token/logout).
  Definite HTTP 429 rejections during authorization, code exchange or refresh
  wait for `Retry-After` plus jitter (at most three retries within two minutes,
  never beyond the credential's expiry). Concurrent token consumers share that
  same rotation and wait. Timeouts, connection errors and 5xx never replay a
  one-use code or rotating refresh token.
  A Keychain/library read failure offers local restoration retry instead of browser
  login. Only an explicit invalid/expired refresh response clears the saved session;
  transient network, rate-limit and server failures retain it. Late concurrent 401s
  reuse an already-renewed token, and a failed Keychain write retries persistence
  before attempting another rotation.
- Automatic onboarding microphone test with 28 frequency bands, sustained-input
  detection, device selection, retry and permission recovery. Test audio stays in
  memory; leaving the step stops capture. The selected device also serves dictation.
- Microphone recording as 16 kHz mono PCM WAV, live metering, stop/cancel,
  a ten-minute recording cap, and explicit retry after failure.
  STT submission relies on the server's authoritative plan/quota checks without
  an extra usage GET for every recording. Temporary rate-limit banners expire at
  the server's retry deadline; quota-exhaustion responses remain distinct from
  short cooldowns. Failed HTTP requests log only method, path and status.
- Fn/Globe or a user-recorded global shortcut, plus a persistent menu-bar control.
  Settings record a key with Command, Option or Control in a focused native
  responder; Escape cancels and Reset to Fn restores the default. The listener
  pauses during capture, ignores key repeats, and persists a new physical key
  binding only after registration succeeds. Common system combinations are
  rejected; other applications may still reserve additional combinations.
  The event tap attaches to the main run loop; its C callback forwards state changes
  to MainActor tasks. Accessibility approval reconnects it automatically.
  See [Apple CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)).
  For the Fn binding, `FnKeyPolicy` backs up the system's `AppleFnUsageType` before temporarily setting
  it to “Do Nothing”. It restores the previous value when the listener is removed
  or the app quits, while preserving explicit user changes. The backup survives
  abnormal termination for recovery on a later run. Like the Electron helper,
  live application uses a dynamically resolved private HIToolbox entry point;
  unsupported macOS versions receive a manual Keyboard-settings fallback.
- A continuous U-shaped extension of the camera housing, with a black foundation
  and restrained native Liquid Glass. The black surface extends behind the physical
  camera to avoid a seam; only hit-testing cuts out the camera. The host disables
  automatic safe-area padding because placement already accounts for the hardware.
  On Fn, both wings widen beside the camera while a 64-point
  control area grows below it; the top stays flush with the screen edge. On completion
  the same silhouette contracts just inside the measured camera bounds and disappears.
  Opening and closing use smooth, non-bouncing transitions; stale animation
  completions cannot hide a newer transition.
  Screen safe area and auxiliary top regions locate the housing; displays without a notch use
  the top centre below the menu bar. Older macOS versions use native
  material; Reduce Transparency uses an opaque surface. A flat line at rest
  blends into seven coral bars with a centre-weighted silhouette, fixed spacing
  and native smooth interpolation. Eight measured frequency groups supply real
  energy and spectral detail; transcription has a separate white processing wave. The visual
  meter uses a noise gate with hysteresis, a 50 ms onset check and separate
  attack/release smoothing. Recording motion follows capture frames rather than
  a timer; preparing the microphone keeps the line still. These filters only
  affect visualization, not recorded audio. Dedicated stop and cancel buttons
  accompany the Fn hint; Fn finishes and transcribes. The camera placement replaces
  freely dragged positions. A recording stays on the display selected at its start;
  disconnecting that display moves the panel to an available screen.
  A hosting canvas sized once for the selected display separates SwiftUI spring
  animation from NSPanel sizing. Reduce Motion substitutes a short fade for movement.
  Transparent margins pass mouse clicks through to the underlying application.
  Errors, microphone interruptions and paste-fallback warnings expand this same
  surface around a 376-point notice with an explanation and countdown ring.
  Paste-fallback notices retain their copy action. Detail-navigation buttons and
  request IDs are omitted from user-facing errors.
  Notice headers use a centred 16-point symbol, 13-point title and compact close
  ring; message text is 12 points. Camera wings contain no decorative mic/Fn labels.
  Dictation status cards do not interrupt Home, Notes or Vocabulary. Errors appear
  in the island; the menu-bar controls retain explicit retry and
  discard actions without repeating the error banner. When history is disabled,
  Home still exposes the latest result for selection and copying.
  Hover pauses expiry; dismissal hides the surface when no recording is active,
  without retrying billable requests or deleting retained audio. Successful transcription returns quietly to
  idle without a “Matn tayyor” notice. Copy actions are available in notices and
  the native context menu, alongside hide-for-now and quit.
  `IslandNoticeCenter` owns notice lifetime; `DictationIslandController` owns the
  nonactivating NSPanel across Spaces/fullscreen; `IslandPresentation` holds the
  reveal state and outgoing notice, `IslandGeometry` calculates display placement,
  and `CameraIslandShape` shares the U contour between rendering and hit-testing.
  Observation tracks lifecycle separately from audio rendering, preserving text focus.
  Desktop's meeting-recording/calendar card
  depends on meeting/calendar services that are not yet implemented in this app.
- Native SF Symbols in onboarding and Liquid Glass on floating/secondary controls
  on macOS 26+, with opaque native fallbacks for older systems or Reduce Transparency.
  Content cards retain their desktop layout. See
  [Apple's Liquid Glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
- Cloud transcription requests automatic language detection (`language=auto`).
  Settings and onboarding have no spoken-language selector; interface language
  remains independently configurable. Backend `/v1/desktop/stt` must deploy the
  explicit-auto fix: older servers interpret auto as a saved/default language.
  The fix forwards `AllowLanguageDetection` and validates the detected result
  before persisting or charging it. Omitted language retains older-client behavior.
  Settings → Writing and the onboarding alphabet step offer an optional
  Uzbek output alphabet, defaulting to the current spelling. The modern variant
  uses `O‘ → Ö`, `G‘ → Ğ`, `Sh → Ş`, `Ch → Ç`, following the
  [2026-09-10 official announcement](https://gov.uz/oz/cirns/news/view/217333)
  of Senate approval; the UI does not assert that the law is already in force.
  `UzbekAlphabetConverter` uses cached regular expressions, preserves case and
  tutuq punctuation, and supports common apostrophe variants. It protects URLs,
  email addresses, domains and backtick code spans. This is mechanical spelling
  conversion, not language detection within mixed-language Uzbek text.
  Old spoken-language preferences are removed. Selecting an alphabet never
  forces a recognition language. The alphabet preference persists locally and is
  captured when recording starts; conversion applies only when the provider
  detects Uzbek. English and Russian results remain in their detected language.
  It never rewrites old notes or
  canonical cloud history. Snippet triggers match the original transcription and
  their literal expansions are preserved. Practice, insertion and copy fallback
  share the same rendered result. The alphabet regression script checks preferences
  and the actual dictation model through native NSTextView insertion, edit
  notifications and encrypted note persistence, using fake audio/network input,
  temporary storage and isolated UserDefaults. It never modifies the user's settings.
- Usage display, paginated cloud history, search, copying and optimistic transcript edits.
  Home is the single place for recordings: a stats summary, then day-grouped recent
  activity with search, Copy, Edit (shared revision-aware editor) and pagination.
  Getting Started provides live permission/shortcut status, an in-app practice area,
  and onboarding review. Review navigation uses an ephemeral checkpoint and can be
  closed without resetting account data or completion. Practice uses the existing
  cloud transcription mode without pasting into another app or adding local history.
  Account activation starts profile/history refresh in the background; history
  loads independently of the usage request. A usage GET retries once after a
  timeout or lost connection, with a cancellable 600 ms delay. Offline/TLS errors,
  HTTP rejections, token exchanges, edits and STT uploads do not use that retry.
  If usage still fails, the last known balance stays visible with a profile
  warning/retry control; it does not create a recording failure in the notch.
  An explicitly invalid refresh session still requires sign-in.
  The profile shows remaining minutes with a proportional bar when the server
  supplies a positive limit. The main window uses a hidden title bar, a fixed
  translucent sidebar (Home, Statistics, Vocabulary, Notes, Getting Started, then
  Settings) and no toolbar controls. Settings float over the workspace as a panel with
  their own sidebar: General, Dictation, Shortcuts, Permissions, Notifications,
  Changelog, and Account. Esc, the red close button, or a click outside closes it.
  General includes appearance previews, an accent color (VoiceLab, System, or a
  preset) and app behavior. Release notes live in `Features/Settings/Changelog.swift`.
  The sidebar is not a NavigationSplitView, avoiding split-view constraint feedback.
  Workspace selection, vocabulary tabs, import panels and hover/press feedback use
  shared SwiftUI motion timings, with Reduce Motion and Reduce Transparency support.
- Account-scoped notes with an encrypted local outbox and dedicated cloud sync.
  Requires backend migration 222 and `/v1/desktop/notes` to be deployed; until then
  local editing remains available and Notes shows a sync warning. Existing notes
  migrate automatically. Creates, edits, pinning and tombstone deletions synchronize
  on open, foreground activation, after edits and every 30 seconds, with failure
  backoff and server rate limits respected. Conflicting edits preserve both versions;
  stale deletes restore the newer remote note. No automatic text merge is attempted.
  Notes API requests bind the access token to the owning outbox account. Local
  persistence is encrypted; server storage is account-scoped, not end-to-end encrypted.
- Vocabulary and explicit phrase replacement remain local.
  Vocabulary matches the desktop's compact Dictionary/Snippets tabs. Dictionary
  words support language selection, add/search, edit, delete, comma/newline batch
  import, UTF-8 text export, and confirmed clear-all that preserves snippets.
  Batch imports validate before applying and skip normalized duplicates within
  each language. Existing vocabulary IDs and replacements migrate without loss;
  legacy entries default to all languages, and replacements appear in Snippets.
  Snippet expansion matches Unicode boundaries and the longest trigger first in
  one pass, so generated text cannot trigger cascading replacements. Replacement
  text is literal and retains newlines. Both collections use encrypted account
  storage; no sync requests or invented cloud statuses are added.
  Vocabulary controls use native Liquid Glass on macOS 26 and an opaque fallback
  on older systems or with reduced transparency. Text rows stay on solid adaptive
  surfaces; only controls use glass. Editing sheets share the same control styling.
- Guarded auto-paste into the originating foreground application; manual-copy fallback.
  VoiceLab's own focused text editor uses `NSTextView.insertText` at the current
  selection, preserving native Undo and SwiftUI note autosave without a clipboard
  round trip. Weak references bind the recording to its original editor, window
  and field-editor delegate; switching fields or notes falls back to copying.
- Light/dark/system appearance and launch-at-login registration.
  `LoginItemService` enables `SMAppService.mainApp` once when running an installed
  copy from `/Applications` or `~/Applications`. Xcode/temporary builds do not
  auto-register. Later opt-outs in the app or macOS are respected; Settings display
  the actual registration status and link to Login Items if approval is required.
  See [Apple SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
  AppDelegate owns startup independently of window visibility. A login launch
  restores the session and installs the shortcut without opening the main window;
  explicit launches and Dock reopen requests show the normal UI. Closing the last
  window leaves the menu-bar app and shortcut running. Quit still terminates them
  until the next launch or login; no keep-alive agent overrides an explicit Quit.
  Settings → General → App → **Always show Dock icon** defaults on. Turn it off to hide
  the Dock icon after closing the main window; opening Echo from the menu bar
  brings it back. Minimized windows keep their Dock icon, while recording overlays
  do not. The preference persists across launches and applies to login launches.
  After a login launch finishes restoring, the notch briefly shows the bundled
  VoiceLab icon and a localized greeting. A ready session includes the configured
  shortcut; otherwise the greeting invites the user to open VoiceLab. It retracts
  after four seconds (paused on hover), opens the app when clicked, and yields to
  recording or actionable notices. Manual launches do not show this greeting.

The onboarding presentation follows `voicelab-desktop`'s `OnboardingFlow.tsx`,
`components/onboarding/ui.tsx` and `--onb-*` color tokens: a centered 1056 × 672
container, 208-point sidebar, neutral light/dark palette, four-column choice grids,
keycaps, and message/email/note practice windows. The original SVG wordmark is
bundled as a template image. `OnboardingDesign.swift` owns the shared components;
feature views keep calling `OnboardingModel` for navigation and actions.

Typography and icons use native macOS system fonts and SF Symbols. Shortcut hints
follow the active binding in onboarding, Settings, the menu bar and the island.
Settings provide separate dictation and interface language choices. Uzbek,
English and Russian interface translations live in `Resources/Localizable.xcstrings`;
`AppLocalization` observes the persisted selection and updates existing views without
recreating note editors. User notes, transcripts and vocabulary remain verbatim.
Content scrolls inside the onboarding
card when a smaller window cannot fit a step, while navigation stays visible.
History, vocabulary and notes retain their existing native macOS presentation.

## Storage and lifecycle decisions

Each account has its own AES-GCM encrypted snapshot and Keychain encryption key.
Associated authenticated data binds each snapshot to its account ID. Writes are
atomic, editing is debounced, and pending changes are flushed on sign-out and quit.
Unreadable data is not silently replaced with an empty library.

The snapshot approach keeps this initial native version dependency-free. It rewrites
the encrypted account snapshot after edits; a paginated database/repository is the
next step if large histories make profiling show meaningful write amplification.

Temporary raw audio lives in a private directory during an operation. Success or
discard removes it; failure retains it for explicit retry during that app session.
Crash recovery and automatic cleanup of orphaned temporary recordings are not yet
implemented.

The existing STT endpoint is billable and accepts no idempotency key. The app does
not automatically retry its POST after an ambiguous failure. A definite
`401 invalid_desktop_token` rejects work before processing: the app refreshes the
token and retries once with the same method/body/upload. A generic 401 or a second
rejection does not loop or erase the refresh token.

Text insertion is coordinated by `TextInsertionManager` on the main actor, with a
transaction gate preventing overlapping clipboard operations. Settings → Writing
provides Automatic, Clipboard and Keyboard modes. Keyboard mode uses UTF-16 Unicode
key-down/up pairs (including emoji), without copying text or issuing Return shortcuts.
Paste waits at least 80 ms on DispatchQueue before Cmd+V and rechecks the originating
app, window, readable field identity and selection. Preparation allows up to 16 polls
for physical modifier release and a stable selection, rebasing spacing when text is
deleted in the same field. A recreated AX text field can be rebound only by a stable,
nonempty identifier and role in the original window. Missing browser AX text alone
does not block pasting. Secure input and target changes stop injection; synthetic
Cmd+V modifier state does not block the next transaction.
The floating island and its hosting view never become key or first responder.

Automatic typing fallback is allowed only before any paste event was posted. CGEvent
has no delivery acknowledgement; unchanged/unavailable AX text cannot establish that
a web editor rejected paste. After posting, no blind retry occurs. Expected AX text
is checked every 80 ms for up to 1.2 seconds. Confirmation permits early completion
and clipboard restoration, only if the user hasn't copied anything else. Otherwise
the transcript remains available for delayed consumers and
manual paste. Cancelled/partial typing is not replayed. Run
`./scripts/test-text-insertion.sh` for deterministic timing, focus, cancellation,
clipboard ownership, concurrency and Unicode regressions with no system input events.
Real browser/Electron acceptance still needs an interactive check.

Auto-paste uses Accessibility and a synthetic Command–V, so this build targets
direct macOS distribution with App Sandbox disabled and Hardened Runtime enabled.
The template's signing team and bundle identifier remain configured in Xcode.

## API contract

Production origin is fixed to `https://api.voicelab.uz`. Auth browser navigation is
restricted to the matching `https://voicelab.uz/app/sign-in` authorization URL.
HTTP redirects are rejected. No credentials are imported from the Electron app.

| Operation | Endpoint |
|---|---|
| Start browser sign-in | `POST /api/v2/auth/desktop/authorizations` |
| Code exchange / refresh | `POST /api/v2/auth/desktop/token` |
| Logout | `POST /api/v2/auth/desktop/logout` |
| Entitlement and usage | `GET /v1/desktop/usage` |
| Transcription | `POST /v1/desktop/stt` (`audio`, `language`) |
| Saved history | `GET /v1/desktop/transcriptions` |
| Notes | `GET /v1/desktop/notes`, `GET/PUT /v1/desktop/notes/{UUID}` (new backend required) |
| Saved transcript edit | `PATCH /v1/desktop/transcriptions/{id}` |
| Onboarding profile | `GET /v1/desktop/onboarding` |
| Save onboarding answers | `PUT /v1/desktop/onboarding` |

Onboarding progress and completion belong to each account's encrypted library.
An interrupted flow resumes at its saved step. A completed local flow goes directly
to the workspace on subsequent launches. The previous device-wide setup boolean is
not used to skip another account's onboarding. Older libraries without onboarding
data decode normally and enter the new setup flow.

An existing server profile prefills the questionnaire on a new Mac, but permission
checks and shortcut verification still run locally. Microphone testing records
only locally and discards its temporary audio. The optional practice exercises
use the real billable STT endpoint, show results inside the tutorial, and do not
automatically paste into another app. Server history retention still follows
the account's existing policy.

Completion is committed locally before entering the workspace. Failed profile
uploads retain a pending flag and retry on launch, foreground activation or the
manual retry button. Writing-style answers are saved as preferences; the current
STT contract does not accept a style parameter, so style examples are not presented
as an implemented automatic rewriting feature. Onboarding UI text is Uzbek;
practice prompts follow the selected Uzbek, Russian or English dictation language.

Authentication uses the existing `voicelab://auth/callback` contract inside
`ASWebAuthenticationSession`; this project does not register a competing global
URL scheme. Apple reference:
[ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).

## Migration scope and verification

The reviewed source is `../voicelab-desktop`, particularly the desktop auth manager,
VoiceLab API client, control-panel sidebar, history, dictionary and sync services.
The current Electron desktop token is restricted to desktop STT, and its generic
cloud sync service is disabled. The native app therefore does not activate those
legacy sync endpoints.

This is the first native implementation of the primary dictation workflow. It is
not yet full Electron feature parity. Remaining migration work includes:

- System-audio meeting capture, meeting detection, speaker separation and calendar integration.
- Optional Fn/Globe push-to-talk mode.
- Rich-text note formatting, folders, notes AI actions and chat.
- Interface languages beyond Uzbek, English and Russian.
- Legacy encrypted database migration and saved-audio playback.
- Automatic updates and provider-specific CDN publishing. The native release
  signing/notarization workflow is documented in [CDN release](docs/CDN_RELEASE.md).
- Crash-safe audio recovery, large-library performance profiling, and full UI automation.

Core tests run offline and do not consume VoiceLab credits. Browser login, actual
microphone capture, Accessibility insertion and production STT require an interactive
signed-in test on the Mac before this should be considered release-ready.

### Authentication recovery

Access-token expiry refreshes the session through a shared actor task; concurrent
requests and late 401 responses do not independently rotate credentials. Tokens
and any pending refresh operation UUID are saved together in Keychain.

When the backend advertises `refresh_retry_supported: true`, the app persists an
operation UUID before refresh and sends it as `Idempotency-Key`. Lost responses
and selected transient server failures retry at most twice with the same UUID.
An interrupted operation can also resume after relaunch. Successful rotation
clears the UUID; a failed Keychain write retains the successor in memory for a
later persistence attempt. Legacy servers do not receive ambiguous-error retries.

Deploy the matching backend recovery implementation before distributing this app.
Refresh sessions still have the server's absolute 30-day expiry; explicit expiry
or revocation requires login. Logout sends the current bearer and refresh token;
offline logout clears local credentials and reports unconfirmed remote revocation.
The protocol and PostgreSQL test commands are documented in the backend's
`docs/desktop-refresh-recovery.md`.

Run `swift test --package-path Packages/VoiceLabCore --disable-sandbox` for offline
regressions covering expiry, 401/429, concurrent refresh, response loss, restart,
Keychain failures, cancellation, logout, and account-bound uploads. These use a
fake transport and secret store; they do not verify live browser login or Keychain
permissions on a distributed signed build.

Confirmed refresh expiry/revocation emits a shared authentication invalidation.
The app immediately gates the workspace behind sign-in, dismisses settings,
stops recording and cloud sync, and preserves account-bound local notes. The
refresh deadline is also watched while the app is idle. Keychain cleanup failures
cannot prevent this routing; offline/429/5xx errors do not invalidate the session.
Fresh login clears the invalidation and restores the saved onboarding/library.

Run `zsh scripts/test-session-routing.sh` for the real AppModel + Authentication
routing regression executable with isolated storage and an injected HTTP transport.
It covers history, usage, dictation, notes, onboarding, expired startup, failed
Keychain removal, offline behavior, preserved drafts, and successful re-login.

### Profile balance

The profile reads the server's remaining seconds and uses the same value for its
minute label and progress ring. Each completed STT attempt (including onboarding
practice and ambiguous network failures) triggers a fresh usage read. Opening the
profile or returning to the app also refreshes it. Concurrent ordinary reads are
coalesced; a read started before a transcription settles cannot overwrite the new
balance. The client never subtracts a local timer or resends audio for this check.
If usage is unavailable, the profile retains the last known balance with a retry
notice.

`zsh scripts/test-usage-balance.sh` exercises the actual app and dictation models
with fake capture/server responses: two-minute deduction, progress, disabled
history, practice, stale/concurrent reads, unbilled failures, lost responses after
settlement, and recovery from a usage fetch failure.

## One-time local development reset

A Debug launch consumes `~/Library/Application Support/VoiceLabNative.reset-request`
before constructing preferences or restoring authentication. `LocalInstallationReset`
restores the temporary Fn policy, removes only the native app's `uz.voicelab.native`
Keychain entries, `VoiceLabNative` local library, bundle cache/saved window state and
`uz.voicelab.desktop` preferences. This bundle preference/cache namespace is shared
with the previous VoiceLab app; use the full reset only on a development account.
Successful reset removes the request; failures retain it and block session
restoration with an explicit error. Cloud data, macOS permissions and the Electron
local database/recordings are unaffected. Release builds ignore the request.

## Workspace design reference

### Statistics

The Statistics destination shows real word counts, duration-weighted words per
minute, recording counts, app usage by task category, daily activity, and streaks.
The screen covers the last 182 days (six months). Streaks are bounded by
this window and allow today to remain empty when yesterday was active.
Application categories come from captured destination metadata, never transcript
contents. The six categories are personal messages, work messages, email, AI
prompts, documents, and other tasks. Percentages use attributed recording counts.
Browser document URL attributes may identify known services (for example Gemini);
only the allowlisted service identity is retained. If that attribute is unavailable,
the browser is classified as other tasks. No URLs, titles, or paths are stored.

Destination context is saved only after insertion is confirmed or its events have
been sent. Clipboard-only results and onboarding practice are excluded. Older
recordings remain unattributed. Calendar cells open a native hover/click popover
with daily words, distinct known apps, and the top app by words.

An encrypted per-account outbox sends idempotent metadata PUTs with backoff, without
blocking dictation. A 404 from an undeployed endpoint retains events; a 410 for a
deleted/unavailable recording clears that event. Server aggregates take precedence
after sync. While events are pending, app charts use local history to avoid double
counting an ambiguously committed write. Provenance is available via the info button.
Run `SWIFT_MACRO_SANDBOX_DISABLED=1 zsh scripts/test-desktop-usage.sh` for outbox,
relaunch, backoff, and account-isolation regression checks.

The account-bound `/v1/desktop/statistics` endpoint returns daily aggregates in
the Mac's timezone, without downloading transcript text. Until the backend is
deployed, the screen uses already-loaded local history and labels it as partial.
Transient errors retain the last server snapshot; switching accounts or signing
out clears statistics. Local word counting runs off the main actor.

These are retained-history statistics, not billing totals: deleting or editing
history changes the metrics without refunding the profile's remaining minutes.

Run `swift test --disable-sandbox --filter StatisticsTests` inside
`Packages/VoiceLabCore` for calculations, and
`SWIFT_MACRO_SANDBOX_DISABLED=1 zsh scripts/test-statistics-model.sh` from the
repository root for fallback, request coalescing, and account isolation.

### Visual reference

The workspace uses the installed Wispr Flow 1.6.1102 Hub as a visual reference:
warm neutral surfaces, compact monochrome navigation, restrained borders, a
shortcut hint and chronological activity grouped by local calendar day. The
installed design resources and the [official Hub description](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)
were inspected; its live window could not be launched from the tool environment.
VoiceLab retains native system typography, SF Symbols and its own functionality.
`HistoryRow` keeps copy/edit controls keyboard-accessible. Liquid Glass
remains on the floating island; reading surfaces use light/dark semantic colors.

## Background return greeting

The embedded `EchoWakeHelper.app` login item keeps listening for session return
while Echo is closed with Cmd+Q. It launches only its enclosing Echo app, without
activating its window. An already-running Echo handles its own unlock greeting.
Closing the window leaves Echo running normally. Cmd+Q exits Echo until the next
unlock or login; it is not immediately relaunched.

Install the signed Echo.app in Applications and enable **Launch at Login** in
Echo Settings (approve it in macOS Login Items if requested). This switch controls
both login launch and relaunch after unlocking. Existing login-item opt-ins migrate
to the helper; opt-outs stay off. Xcode/temporary builds do not register a persistent
helper. They can preview unlock greetings while the main app is running.

The event monitor uses workspace sleep/session events and WindowServer screen-lock
notifications, coalesces duplicate events, and has no idle polling loop. Unlock
notifications/lock state need a smoke check on supported macOS versions because
Apple does not document the screen-lock notification names as stable public API.
The greeting lasts four seconds, does not activate Echo, and yields to recording
or actionable notices.

Automated event checks: `./scripts/test-session-return.sh`.
Before distribution, test with a signed installed build: lock/unlock, close the
window then unlock, Cmd+Q then unlock, restart/login, disable Launch at Login,
and verify recording is not interrupted by a greeting. Signing and actual login
item approval cannot be validated by an unsigned Xcode build.
