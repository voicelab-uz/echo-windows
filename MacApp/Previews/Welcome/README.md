# Onboarding visual preview

A standalone macOS SwiftUI preview for iterating on Echo's onboarding screens.
Setup tests a real microphone locally. Try it connects real speech to VoiceLab Cloud
using the app's existing recorder, browser authentication, and DesktopAPI.
Get started opens Permissions; after both simulated grants, Continue opens Setup.

Build from the repository root with Xcode's command-line tools installed:

```sh
./scripts/build-welcome-preview.sh
```

Open `.build/welcome-preview/EchoWelcomeConcept.app` to review it. The builder
reuses the repository's brand assets, and includes all seven Manrope weights,
their SIL Open Font License, and 16-language copy throughout the preview. Languages with
scripts outside Manrope's coverage use macOS fallback fonts. The translations
are design drafts for review before production integration.

The MacBook demo loops automatically: a simulated `fn` press unfolds the
recording island from the camera notch, and the next press turns the sample
speech into a message to Aisha before the island retracts. The preview reuses
the app's pure `CameraIslandShape` geometry without its services. No interaction is
needed. This is a visual simulation; it does not listen for the physical
keyboard's Fn key or record audio.

Playback continues without requiring focus or interaction. Reduce Motion shows
a static result. The compact language selector remembers the chosen language.
Production onboarding is independent of this preview.

Native trackpad haptics mark changed selections, permission grants, the first Fn
validation, a completed microphone check, and forward navigation. They do not run
for hover, autoplay, repeated selections, or microphone start/stop. Requests are
throttled and limited to the active app with a key window. The default AppKit
performer handles supported hardware and system feedback preferences.

Permissions demonstrates each grant separately in a macOS System Settings
illustration with its sidebar, Privacy & Security selection, native typography,
and permission rows. The sidebar, permission descriptions, prompt, and buttons
follow the selected onboarding language. The illustration keeps native macOS
typography while the surrounding onboarding uses Manrope. On macOS 27, the control-access pane uses the observed
“Device Control and Data Access” title; earlier versions show “Accessibility”.
An animated pointer clicks Allow on the microphone prompt. This is the only demo
that loops until the microphone's Allow button on the left is pressed. It then
shows only the Accessibility switch walkthrough, and holds the enabled switch
once both permissions are allowed. Playback never grants preview permissions by
itself. Changing language preserves these local grants. Reduce Motion keeps the
demonstration with fades and removes pointer movement.
All windows, prompts, and switches in the illustration are inert SwiftUI drawings.
Allow buttons on the left only change local preview state and never invoke macOS
permission prompts. Continue opens Setup after both simulated grants. Going back
from Setup preserves them; returning to Welcome clears them.

Setup lists the Mac's available microphones plus System default. Try microphone
requests macOS microphone permission and starts a local meter using the existing
MicrophoneCapture service with `recordingURL: nil`. A single centered check contains
the microphone selector, a compact waveform, and one primary action. Eight measured,
smoothed frequency groups are mirrored for a balanced shape with rounded ends.
There is no generated oscillation or automatic completion timer; silence returns
the waveform to small dots. Once sustained input is detected, Continue replaces
the test action. It stops capture and opens a visual introduction to the Fn shortcut.
Going back preserves the successful trial; selecting another microphone resets it.
Stop, leaving
Setup, or closing the window releases capture. Changing devices while listening
restarts the test on that device and discards old callbacks. Permission errors and
disconnections offer localized guidance. Device names come from macOS.

The Setup microphone check processes audio in memory without saving or uploading it.
The separate Try it step records and uploads only after explicit Fn actions.
The build is ad-hoc signed so macOS can identify the preview's microphone
request; rebuilding may require granting permission again. Welcome and Permissions
remain visual simulations. The shortcut exercise accepts only the physical Fn key
while the preview window is focused. The drawn key is not clickable; Enter, Space,
and other keys cannot validate it. Fn depresses the key and sends a soft circular
shimmer from its center outward. Held keys trigger once, and focus loss releases
the visual key. A local AppKit monitor is removed when leaving this step; it never
installs a global hook, changes keyboard preferences, or starts audio capture.
Reduce Motion uses color and success fades without the expanding ring or key motion.

After Fn validation, Continue appears and opens the existing next setup step:
Uzbek alphabet preference. These choices stay local to this preview. Going back
preserves Fn validation and the selected alphabet.
The alphabet screen compares large Manrope letter specimens side by side, with
a checkmark and border on the selected option. A shared text sample fades between
the two spellings. Labels follow the interface language; Uzbek specimens keep
their left-to-right order. Reduce Motion removes the press and checkmark scaling.
The fixed Continue button opens Sign In, and Back preserves the alphabet choice.
The six-stage progress header ends with Try it: Welcome, Access, Setup, Sign In,
About you, and Try it. There is no Personalize or extra completion page.

Sign In presents a focused browser sign-in button. The writing input and Fn listener
remain hidden until a session is restored or browser sign-in succeeds. Repeated
clicks cannot open duplicate sign-in attempts, and Fn does not launch sign-in.
After successful login, About you loads the account’s saved questionnaire. Once
all six questions are answered or skipped, the progress header advances to Try it, which presents an
editable Manrope writing area with a physical Fn instruction and no clickable start
action. Capture requires a fresh Fn press after returning. A separate Keychain service
(`dev.echo.onboarding-preview`) stores this preview session so it does not rotate
the production app's credentials. The browser uses the existing PKCE and loopback
callback flow. No credentials are stored in preview preferences or resource files.

The trial uses a compact writing surface and a separate dark recorder with a
physical Fn key cue. Listening shows measured voice levels and a finish instruction;
processing keeps the recorder in place; success changes the heading, briefly
highlights the editor, and explains that the text is editable. After a successful
trial, a real Next button replaces the recorder and closes the onboarding window.
Typing alone cannot unlock it; editing or clearing a successful result keeps it
available. Another Fn press starts a new trial and restores the recording controls.
Next stays hidden during recording, processing, or an error. Errors sit beside
the editor. The key cue never accepts mouse clicks; only Cancel and the completed
trial's Next button are interactive. Reduce Motion keeps state fades and removes
key movement. The trial has no cloud-usage footer text.

Once signed in, Fn starts recording with the selected microphone. The compact
waveform reflects actual capture frames, and the next Fn press stops capture and
submits one WAV to the existing `/v1/desktop/stt` endpoint. Transcription uses the
VoiceLab account's plan.
The existing recorder's ten-minute limit also ends and submits capture. The
interface language does not constrain speech detection. The alphabet selected at
capture start applies only to detected Uzbek. Completed text appends to the editable
input, preserving any edits made while transcription runs, and success requests
one native haptic. No clipboard insertion or local history is created.

Cancel, Escape, Back, and closing the window release capture. Focus loss discards
an active recording without submitting it, while opening the sign-in browser is
allowed. Temporary recordings are deleted after completion, failure, or cancellation
cleanup. Late replies cannot insert text after cancellation. Requests are not
automatically replayed after ambiguous failures; only the existing API client's
typed pre-processing authentication rejection may refresh and retry once.
Uzbek interface copy uses the modifier letter turned comma
`ʻ` (U+02BB) in `Oʻ` and `Gʻ`, matching Unicode CLDR's Uzbek exemplar letters.
Manrope lacks this glyph, so Core Text supplies a native fallback for the mark.
This keeps the correct turned-comma shape instead of Manrope's quotation glyph.

Run `./scripts/test-setup-shortcut.sh` for focused checks of Fn-only validation,
wrong keys, held/repeated keys, focus loss, and retained success.

Run `./scripts/test-setup-microphone.sh` for hardware-free regression checks covering
real meter frames, silence, Continue gating and capture release, no recording URL, device switching, stale callbacks,
permission retry, disconnected inputs, and cancellation during startup.

Run `./scripts/test-try-it.sh` for isolated checks of Fn-only capture, browser sign-in,
selected input, measured levels, exactly-once submission, editable results, alphabet
selection, cleanup, focus loss, and cancellation during capture startup or upload.
These tests use controlled capture and transcription doubles; a physical Fn press
and an authenticated account are required for an end-to-end spoken trial.

## About you and backend persistence

Six optional, localized questions collect discovery source, intended uses, work,
writing contexts, meeting apps and meeting difficulties. One question appears at a
time in the left pane, with wrapping single- or multi-select choices, a
280-Unicode-scalar Other field, and Skip. The right pane shows six native SwiftUI
illustrations, including a Mac workspace, writing surfaces and meeting notes.
Choices show matching brand logos from `icons/` or native symbols beside their
localized titles. The build compiles the supplied SVGs into vector image assets;
no remote images are loaded. Generic search and AI choices keep generic symbols.
These are inert illustrations; they never inspect apps or start recording. Reduce
Motion shows a static state, and navigation cancels the illustration task.
The footer explains that the answers help improve Echo. No contact lists, installed
apps, meeting recordings or transcripts are collected by this questionnaire.

Next and Skip save the full draft to the authenticated
`PUT /v1/desktop/onboarding/context` endpoint before moving forward. The final
acknowledged save marks the questionnaire complete and opens Try it. Back allows
reviewing earlier answers. `GET` restores the server draft or skips an already
completed questionnaire. Unsubmitted selections are memory-only; closing before
Next does not persist them. All questions can be explicitly skipped.

Pending requests disable editing. An uncertain failure retains the exact payload
and mutation UUID for Retry, preventing duplicate history after a timeout. A 409
requires reloading the server copy; a 422 allows editing. Expired authentication
returns to Sign In. Cancellation ignores late responses. No fallback silently
marks a failed save as complete, and a missing backend route is shown as an error.

Deploy the companion Go backend and migration 178 **before** distributing this
preview. The backend contract, option IDs, admin retrieval and SQL examples are in
`../back/docs/echo-onboarding-context.md` relative to the Echo repository root.
The legacy web account-onboarding endpoint and production app onboarding are unchanged.
All translations are design drafts and should receive native-speaker review.

`./scripts/build-questionnaire-preview.sh` builds a separate design review app at
`.build/welcome-preview/context-review/EchoContextReview.app`. It starts at About
you and holds questionnaire answers in memory only; those answers are never sent
to the backend. The last question opens the shared Try it interface, restoring the
preview session or offering Sign In. Speech uses the real authenticated service
and the default microphone, with the same physical-Fn and successful-trial gates.
Back returns to the answers. Closing discards the local questionnaire. Use the
normal welcome preview to verify server persistence and the complete setup flow.

Run `./scripts/test-questionnaire.sh` for choice rules, Unicode limits, explicit
skips, server-confirmed navigation, retries, revision conflicts, resume and stale
responses. Run `swift test --package-path Packages/VoiceLabCore --filter onboardingContext`
for the authenticated wire contract and response validation.
