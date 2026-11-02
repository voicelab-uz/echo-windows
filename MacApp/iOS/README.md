# Echo for iPhone

This iOS app and keyboard extension live alongside the Echo macOS app. The keyboard types normally, and its microphone button opens the host app for a user-started recording. Only the host app accesses the microphone; the extension receives the finished transcript through an App Group and inserts it into the current text field.

## Build

Open `Echo.xcodeproj` in Xcode, select the `Echo` scheme, choose an iPhone, and configure a signing team for both the app and keyboard extension. Both targets must use the same App Group (`group.uz.voicelab.echo.shared`). The Xcode targets are Echo and EchoKeyboard. The app bundle ID is `uz.voicelab.echo.ios`; the keyboard is `uz.voicelab.echo.ios.keyboard`. Source folders retain their original names. These identifiers create a separate installation from earlier VoiceInput test builds; users must sign in and enable the keyboard again.

For a compile-only check:

```sh
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The app requires iOS 17 or later. On first launch, onboarding guides the user through Google or Apple sign-in, microphone permission, keyboard activation, Full Access, and language/alphabet preferences. Add Echo at Settings → General → Keyboard → Keyboards. The first keyboard Start activates the host app in the foreground; subsequent dictations reuse that capture session without reopening Echo. The default ready session keeps the microphone active between takes, discards idle buffers, and only saves/uploads dictated audio. Its indicator remains visible until the session ends. It expires after five idle minutes while Echo is backgrounded and its keyboard is closed. A short visibility lease prevents a killed extension from keeping the session alive. A visible keyboard or foreground app refreshes the idle countdown; the five-minute recording limit remains independent. Settings and the keyboard menu offer recording-only mode, which releases the microphone after every take and may reopen Echo at the next Start. Changing modes during a recording applies to the next session; an idle ready session stops immediately when recording-only is selected. App launch alone never activates the microphone. The keyboard menu, Settings, and Echo’s Dynamic Island controls can end an active session immediately. Returning to another app does not cancel a take. Start reads fresh shared state before deciding to open Echo, duplicate handoffs are gated until acknowledgment or timeout, and rejected audio activation closes the unusable session. In-app note dictation releases the microphone when its utterance ends.

## Backend and credentials

The app uses Echo's account-based PKCE authentication and the desktop STT endpoint (`/v1/desktop/stt`), plus onboarding context/completion endpoints. Access and refresh tokens are stored in the iOS Keychain. No VoiceLab API key belongs in the app bundle; do not add one to `Info.plist` or commit `Config/Secrets.xcconfig`.

The in-app Statistics screen reads the account's six-month dictation aggregate from `/v1/desktop/statistics`. The backend's `source_platform` migration separates new iPhone dictations from Mac dictations; older records default to desktop. Totals, speed, active days, streaks, and the heatmap include both. iOS cannot identify the host app of a keyboard extension, so per-app desktop usage remains Mac-only.

The deployed dev backend accepts `platform=ios` and native PKCE sessions. Keep iPhone sessions labeled `ios`; do not relabel them as `darwin`. Production authorization and OAuth configuration must be verified independently of a successful local build.

## Native Google sign-in

The welcome screen uses Google's official `GoogleSignInSwift` button and
GoogleSignIn SDK (Swift Package Manager). The welcome screen offers only native Google and Apple sign-in. The SDK handles Google's consent UI and
callback; Echo does not open the VoiceLab sign-in website for this flow.

`GIDClientID`, `GIDServerClientID`, and the reversed iOS client URL scheme are
checked into `Info.plist` and `project.yml`. These are public client identifiers;
no client secret is needed or bundled. The iOS OAuth client must match
`uz.voicelab.echo.ios`; the Web/server client must be allowed by the backend.

The established iOS client is `37456461335-cosrlss6qr4fss01obdv22ptlad6lffn.apps.googleusercontent.com`.
Its Web/server client is `37456461335-k32kqvncl69ko874mbdtb49boonk1aci.apps.googleusercontent.com`.
Echo calls the dedicated `POST /api/auth/google/ios` endpoint, which explicitly
verifies this native audience without changing the website's Google client.
Deploy that backend route before installing this mobile release. A website's
Google button configuration alone does not establish the native API audience.
The original downloaded Google iOS plist names `uz.voicelab.echo`; the current
ZEHN AI app uses `uz.voicelab.echo.ios`. A physical Google sign-in must confirm
the registration works with that bundle; never claim a compile proves it.

Debug and Release builds use `https://api.voicelab.uz` for both auth and STT.
Only builds explicitly compiled with `ECHO_DEV_ENVIRONMENT` use the dev server.
Dev Keychain sessions use a separate
service suffix so tokens never cross environments. A previously installed
production session will not appear when switching to the dev build.

Flow: SDK ID token → `/api/auth/google/ios` → approve a PKCE authorization →
`/api/v2/auth/desktop/token`. Echo persists only the native token pair, revokes
the temporary web refresh cookie best-effort, and clears SDK sign-in state.
The temporary cookie jar is ephemeral and isolated from Safari and other app
requests. Existing native refresh, profile, STT and logout continue unchanged.

The dedicated iOS route pins the checked-in `GIDServerClientID`. Keep the existing
website `GOOGLE_CLIENT_ID` unchanged. Ensure the Google consent screen permits
the tester when the OAuth project is in testing mode. No production secret is required.

Device checks: complete Google sign-in; cancel it; retry after a network error;
verify profile identity and STT; relaunch to restore the session; sign out and
sign in with another Google account. A build/typecheck alone does not verify
Google Console configuration or the deployed backend environment.

## Uzbek keyboard assistance

The Uzbek keyboard offers on-device dictionary suggestions and conservative
space-triggered autocorrection in both modern (`Ö Ğ Ş Ç`) and current spelling.
The suggestion strip keeps the typed spelling available; tap a candidate to
complete the word. Backspace immediately after an automatic correction restores
the original word. Settings → Keyboard has separate Auto-correction and Word
suggestions switches; reopen the keyboard after changing them.

Typing assistance uses a bundled common-word dictionary, not a contextual language
model. It does not transmit typed text or require Full Access. Vocabulary coverage
is limited, especially for names, slang, and inflected forms. Voice dictation still
requires its existing account and Full Access flow.

Device verification: check modern and current spelling; type a typo then space
and Backspace; accept a completion; keep an original spelling; move the cursor
into a word; select text; switch host fields; disable each setting; and verify
email/URL fields and host fields with autocorrection disabled stay untouched.

## Profile

Open Profile from the bottom tab bar. Settings and keyboard session controls live inside Profile. The screen restores
cached identity and fetches `/v1/desktop/me`, `/v1/desktop/usage`, and
`/api/v1/billing/desktop/subscription`. The screen keeps loaded data when switching tabs and fetches independent sections concurrently. Individual failures have retry controls,
and pull-to-refresh reloads account data. Usage is dictation time, not a wallet
balance. Name/photo editing uses the website because those mutation endpoints
currently require website JWT authentication rather than native tokens.

Sign-out stops microphone sessions, removes the Keychain session, clears the
local onboarding/account view, and returns to welcome. Remote session revocation
is best-effort; generation checks prevent an older refresh from restoring the
local session after logout. Session-only drafts and notes are cleared on logout.

Run `scripts/test-echo-profile-api.sh` for account, quota, statistics device attribution, and paginated history decoding regressions. Live production behavior requires separate environment verification.

## Dictation history and output script

The Notes tab loads account dictations from `/v1/desktop/transcriptions`, refreshes after completed app/keyboard dictation, and supports pull-to-refresh and pagination. Server dictations persist across app launches; manually saved draft notes remain session-only. The list shows compact text previews; tapping opens the full text, and swipe/context actions expose copying. Device statistics use `platform_days`; aggregate `days` are not treated as desktop-only records.

Profile → Settings → Uzbek transcript script selects current Latin, modern Latin (`Ö Ğ Ş Ç`), or Cyrillic. New Uzbek transcriptions and history display/copy use that preference; reported non-Uzbek utterances remain unchanged. Deterministic conversion protects links, email, code, and identifiers. Unmarked foreign prose in an Uzbek utterance and dictionary-dependent loanword spelling can remain ambiguous.

## Keyboard interaction

The keyboard uses familiar QWERTY positions. Hold `o`, `g`, `s`, or `c` for the selected Uzbek alphabet variants. UIKit handles independent touches, full-cell hit targets, slide-to-key release, character previews, and cancellable delete repeat. Shift supports press-and-drag capitalization. Keyboard clicks follow the system sound preference. The palette follows the host field's explicit light/dark keyboard appearance.

The left menu opens in-keyboard language, alphabet, prediction and autocorrection controls. ABC returns to typing. Pro and Settings open the corresponding Echo account surfaces. The containing app must be opened for the first user-started voice session because keyboard extensions cannot record audio directly.

The draft has an explicit keyboard-dismiss control and a downward dismissal gesture. Hiding the keyboard preserves the draft. The Echo logo button starts dictation.

Additional regressions:

```sh
zsh scripts/test-native-key-hit-testing.sh
zsh scripts/test-uzbek-transcript-script.sh
zsh scripts/test-uzbek-keyboard-dictionary.sh
```

## ZEHN AI TestFlight (production API)

The paid distribution team is `L5FXR2YA4Q` (ZEHN AI, MCHJ). The earlier personal-team identifiers cannot be registered under this team, so distribution uses `uz.voicelab.echo.ios` and `uz.voicelab.echo.ios.keyboard`, sharing `group.uz.voicelab.echo.shared`. This installs separately from the earlier personal build; enable the new keyboard again. Google iOS OAuth must also allow this bundle ID before native Google sign-in can work; the welcome screen offers Google and Apple sign-in.

Run `zsh scripts/archive-ios-testflight.sh 3` from the repository root, increasing the build number for later uploads. This creates a Release archive using `https://api.voicelab.uz` for authentication and transcription. Upload the archive to the ZEHN AI App Store Connect account using Xcode Organizer. The separate `archive-ios-testflight-dev.sh` script is an explicit opt-in to the development server; do not use it for production builds.


## iOS build 13

Echo’s Live Activity shows the session on Dynamic Island and the Lock Screen with a real recording timer and sampled level. Stop finishes a take; End releases the microphone. Controls carry a session ID, so an old activity cannot stop a later session. Disabling Live Activities does not prevent dictation. No recording status banner occupies the home page.

Modern Uzbek mode displays Ş, Ç, Ö and Ğ directly; the English layout keeps W and C. Transcript script preferences are shared with the host immediately, including background keyboard dictation. An explicit Cyrillic output choice survives keyboard alphabet changes. Hold Space for 350 ms, then drag horizontally to move the cursor; a stationary hold or cancelled trackpad gesture inserts no space.

Statistics shows a server-computed estimate for the retained 182-day window, using a documented 40-word-per-minute typing comparison. Platform breakdowns are alternate views and are never added to totals.

The local Debug billing preview reads public prices independently of native authentication. Cards require an authorized cards read, and purchases require current subscription and pending-payment checks. Debug launch flag `--echo-diagnose-billing` runs five fixed read-only GETs and records only redacted statuses, codes, and request IDs in the app cache; Release excludes the probe. The payment preview remains gated from the public Release UI.
