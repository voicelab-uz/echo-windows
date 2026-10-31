# Voice Lab Echo — Windows handoff

Everything needed to build the Windows app as a twin of **Echo for macOS**: same brand, screens,
flows, copy (16 languages), server API and text rules. Assets are exported from the Mac app;
nothing here is a placeholder unless marked **stand-in**.

> Source of truth: the Mac app in `voicelab-uz/echo` (`Voicelab/`, `Packages/VoiceLabCore/`).
> When this document and the code disagree, the code in `Reference/` wins.

---

## 1. Folder map

| Folder | What it is | Use on Windows |
|---|---|---|
| `Brand/colors.json` | Every app colour, light + dark | Theme resource dictionary |
| `Brand/Logo/` | App icon 16–1024 px, sidebar logo | Splash, About, installer, Store |
| `Brand/Fonts/` | Manrope (OFL licence) | Onboarding only (see §3) |
| `Icons/app-icon.ico` | Multi-size icon 16–256 | `.exe`, window, taskbar |
| `Icons/tray-icon-*.ico` | Mac menu-bar mark, idle + recording, light/dark taskbar | Notification area |
| `Icons/logo.png` | 256 px app icon | Sidebar header next to "Echo" |
| `Icons/Navigation/` | 6 sidebar icons: plain, `@2x`, `-dark`, `-active-*` | Sidebar |
| `Icons/IconSet/` | All 38 Mac workspace icons as SVG + PNG 24/48 light/dark, plus Statistics (Fluent, MIT) | Everything else |
| `Icons/ThirdPartyApps/` | App logos shown in the "About you" questionnaire | Onboarding |
| `Onboarding/Copy/` | All onboarding text, 16 languages (JSON) | Onboarding screens |
| `Onboarding/*.png` | Icon-only **fallbacks**. The real illustrations are drawn in code (§5.1) | Only if code drawing is impossible |
| `EmptyStates/` | Empty History / Notes / Vocabulary, light + dark | Empty views |
| `Localization/` | All 677 interface strings × 16 languages | `.resw` / `.resx` |
| `Reference/VoiceLabCore/` | The Mac's shared Swift core + tests | Port API, auth, text rules |
| `Reference/Onboarding/` | The Mac's onboarding screens and **illustration drawing code** (SwiftUI) | Port each illustration (§5.1) |

---

## 2. Brand

**Name:** Echo (by VoiceLab). Window title "Echo". Sidebar header: logo + "Echo" (23 pt semibold).

### Colours (`Brand/colors.json`)

| Role | Light | Dark | Notes |
|---|---|---|---|
| **Accent (VoiceLab blue)** | `#3D63F2` | `#7394FF` | Default accent. Buttons, active icons, charts, focus |
| Text / icons (ink) | `#1A1A1A` | `#E9E8E1` | `WorkspaceAccent` |
| Window background (sidebar) | `#F5F4F0` | `#202020` | `WorkspaceSidebar` |
| Content panel | `#FCFCFB` | `#1A1A1A` | `WorkspaceCanvas`, rounded 26 px panel inset in the window |
| Cards / surfaces | `#F5F4F0` | `#202020` | `WorkspaceSurface` |
| Selected sidebar item | `#EEEBE3` | `#30302F` | `WorkspaceSelection` |
| Hover (sidebar, rows) | accent @ 12 % | accent @ 12 % | Fade 80 ms |
| Muted text | `#6E6E75` | `#A6A6B0` | `OnboardingMuted` |
| Success | `#16A34A` | `#22C55E` | Copied check, "Well done", Allowed |
| Error / warning | Windows system critical / caution | | Mac uses system red / orange |

**Accent setting** (Settings › General): VoiceLab (default), Follow system, then the macOS palette
Blue, Purple, Pink, Red, Orange, Yellow, Green, Graphite. On Windows "Follow system" = the Windows
accent colour. Every accent-coloured element must follow the choice (sidebar active icon, charts,
toggles, tab underline, search icon, rings).

**Appearance:** System / Light / Dark, with fixed-size preview cards on the right of the row.

### Typography
- App UI: the system font (**Segoe UI Variable** on Windows; SF Pro on Mac). Page titles 26 semibold,
  section titles 15 semibold, body 13–14, captions 11–12.
- Onboarding only: **Manrope** (`Brand/Fonts`, OFL).
- Statistics numbers: tabular figures; Home overview numbers use a serif face (Mac: New York).

### Shape and motion
- Corner radius: content panel 26, cards 12–14, sidebar items 10, buttons 8.
- Hairlines 0.75–1 px at ~8–12 % ink. No heavy shadows except the floating Settings panel.
- Motion: short and snappy (80–350 ms ease-out). No page cross-fades when switching sidebar items.
- Respect "Reduce motion" (Windows: *Animation effects* off).

---

## 3. Window layout

```
┌───────────────────────────────────────────────────────────────┐
│ [≡]                                     [🔍]  [☀/☾]  [🔔]       │  title bar / toolbar
├──────────┬────────────────────────────────────────────────────┤
│ (logo) Echo│ ╭──────────────────────────────────────────────╮  │
│          │ │                                              │  │
│ ⌂ Home   │ │          page content (rounded panel)        │  │
│ ▥ Stats  │ │                                              │  │
│ ◫ Vocab  │ │                                              │  │
│ ✎ Notes  │ │                                              │  │
│          │ ╰──────────────────────────────────────────────╯  │
│ ⚙ Settings                                                    │
│ (◯S) Name · Creator · 174 min left                            │
└──────────┴────────────────────────────────────────────────────┘
```

- **Sidebar** 224 px; collapses to 64 px (icons only) with the toolbar toggle (Ctrl+Shift+S). Items
  44 px tall, icon 21 px, text 14 medium. Selected: `Selection` fill, accent icon. Hover: accent 12 %.
  Switching is instant (no sliding highlight).
- **Profile row** (bottom): avatar with a ring showing remaining minutes (accent, 1.75 px). On every
  window open the ring sweeps from 0 to the current value (1.1 s ease-out). Click → popover above
  the row: name, email, plan + minutes bar, Settings, Open Echo account, Sign out (confirm).
- **Toolbar**: sidebar toggle (left); search (Home only), theme toggle, notifications (right).
  Theme toggle plays a circular reveal from the button.
- **Settings** opens as a floating panel over the window (inset ~44 px), red close dot (14 px) at
  top left, its own sidebar (General, Dictation, Shortcuts, Permissions, Notifications, Changelog).
  Esc or click outside closes it. While open, the page underneath takes no pointer input.

---

## 4. Screens

### Home (History)
- Greeting "Hi, {first name}".
- **Overview card** (outlined): "6 months" · Words dictated · Words per minute · Day streak, then a
  row "Statistics →".
- **Recent activity** heading (14 px gap below), then one rounded container grouping recordings by
  day ("Today", "Yesterday", date). Each recording is a card: text (14), time below (11, muted).
  Copy + Edit icons sit on the right, vertically centred, visible on hover only; their space is
  reserved so text never reflows. Copy → icon becomes a green check that pops in, 1.4 s, plus a
  light haptic where available. No background hover tint on cards.
- **Search** lives in the toolbar: a magnifier (accent colour) that expands into a 220 px field;
  folds back when empty and you click elsewhere; Esc clears.
- Empty: `EmptyStates/no-history.png` + "Start with your first thought" + shortcut hint.

### Statistics
Source: `GET /v1/desktop/statistics` (§7). All numbers cover 6 months.
1. Row: **Words per minute** (half-circle gauge 0–200+, number inside the arc) · **Recordings** +
   active days · **Words dictated** + bars for the last 7 days (today full accent, others 55 %).
2. Strip of three: **Time saved** (accent) "Compared with typing at 40 WPM ✎" (typing speed editable
   10–200, default 40, persisted) · **Words today** "N recordings · Xm saved" · **Average length**.
3. **Desktop usage** by category (personal, work, email, AI prompts, documents, other) with
   percentage bars · **N day streak** heatmap (6 months, 5 shades, "Less … More").
4. **Mac / iPhone** split (Windows: show Windows + iPhone; see §7.3).

Time saved = max(0, words ÷ typingWPM × 60 − speaking seconds). Format "4h 20m", "12m", "< 1m".

### Vocabulary
Two tabs, underlined (accent): **Dictionary** and **Snippets**. Header: title, *Import* (dictionary)
and *Add new* (accent). Tool row on the right: expanding search, language filter, ⋯ (Export,
Delete all), count. One bordered list; rows show `word`, `misspelling → correct`, or
`phrase → text`; edit/delete on hover; double-click edits. Each tab has a dismissible dark
explainer banner (gradient, serif title) with two examples:
- Dictionary: "voys lab" → VoiceLab, "toshkant" → Toshkent.
- Snippets: "telegramim" → t.me/voicelab, "emailim" → salom@voicelab.uz.

**Add to dictionary** sheet: toggle *Correct a misspelling* (ⓘ "When Echo hears this word, it
automatically replaces it with the correct spelling.").
Off → one field + language. On → `Misspelling → Correct spelling`. **Add snippet** sheet:
"Say this" + "This text is inserted".

### Notes
Left list (260 px drawer, slides in/out 340 ms) with search and new-note button; editor on the right
(title 27 semibold, body 15, word count). Right-click / two-finger tap on a note: Rename (inline),
Pin/Unpin, Copy, Delete (confirm). Syncs with `/v1/desktop/notes`.

### Notifications (toolbar bell)
Popover 340 px: header with unread count and "Mark all as read"; rows with grey bell icon, title,
relative time, 3-line body, unread dot. Footer only when notifications are off: "Turn on
notifications" switch. No VoiceLab logo in this popover.

### Settings pages
- **General:** Appearance (3 previews), Accent colour, App language (16), Always show tray icon,
  Launch at login.
- **Dictation:** Uzbek alphabet (current / new), Auto-paste, Text insertion method (Automatic /
  Paste / Type), Keep local history.
- **Shortcuts:** Dictation shortcut (inline recorder + ↻ re-record), Activation mode, Paste last
  transcript (Ctrl+Alt+V).
- **Permissions:** Microphone, (Mac: Accessibility → Windows: none needed for SendInput; UI
  Automation for reading the field).
- **Notifications:** push on/off.
- **Changelog:** release notes.

All selectable values use a compact right-aligned menu: `Value ⌃⌄` in the accent colour.

---

## 5. Onboarding (6 stages)

Progress bar: **Welcome · Access · Setup · Sign In · About you · Try it**. Every step has a hairline
footer with text-only **Back** (outlined) and **Next** (white in dark mode, ink in light).
All copy is in `Onboarding/Copy/*.json` (16 languages; `{fn}` = the user's chosen key).

| # | Route | Content |
|---|---|---|
| 1 | `welcome` | Hero + language picker (top right). Primary "Get started". |
| 2 | `permissions` | Microphone (+ Mac Accessibility). "Allowed" badges: green tint + border + shadow. Continue enabled when all allowed. |
| 3a | `microphone` | Starts listening **automatically**; device picker; live bars; "Do you see the bars move when you speak?" + **Yes, I see them**. |
| 3b | `shortcut` | Split screen. Left: 4 keycaps (see §6), "Well done" under the key after pressing it, ⓘ note "You can switch between hold and toggle anytime in Settings → Shortcuts", reserved space for the custom recorder. Right half: a laptop keyboard drawing; the chosen key glows blue around its edge (350 ms), brighter while held. |
| 3c | `alphabet` | Current vs New Uzbek Latin cards (no bounce) + example line. |
| 4 | `signIn` | Browser sign-in (§7.1). |
| 5 | `aboutYou` | Questionnaire (role, apps from `Icons/ThirdPartyApps`, …), Skip available. |
| 6 | `practice` | "Try it": dictate into a practice field with the real shortcut. |

### 5.1 Onboarding illustrations: draw them in code

The Mac has **no illustration images**. Every onboarding scene is drawn and animated in code, and
the Windows app must do the same: the AI or developer building it **draws these illustrations
itself** (XAML shapes, Composition/Win2D, or Lottie authored from this spec), porting the SwiftUI
in `Reference/Onboarding/`. Use the PNGs in `Onboarding/` only as a last-resort fallback.

Rules for every scene:
- Vector shapes only, in the brand colours (`Brand/colors.json`, `Onboarding*` tokens). The only
  bitmaps allowed are the app logo and the questionnaire app logos (`Icons/ThirdPartyApps`).
- All text comes from `Onboarding/Copy/*.json` in the user's language; mirror for Arabic/Urdu.
- Scenes are **demonstrations only**: they never record audio, press real keys or open Windows
  Settings. The one exception is the microphone step, which shows the real microphone level.
- Loop while visible, pause when hidden. With *Animation effects* off, show one still frame.

| Step | Mac source (port this) | What to draw on Windows |
|---|---|---|
| Welcome | `WelcomeDemo.swift` | A laptop (640×400, scales down) showing a desktop with a text field. Below it, a keycap of the user's dictation key plus a caption. Loop: **ready** → key pressed, a floating pill opens at the top of the screen with a 7-bar voice waveform (**listening**) → pill shows working (**processing**) → the sentence appears in the text field (**complete**). Captions are `captions[0…3]` in `WelcomeLanguages.json`. |
| Access | `PermissionSettingsDemo.swift` | A drawn **Windows Settings** window at *Privacy & security › Microphone*: a pointer moves to "Let desktop apps access your microphone" and switches it on; the highlighted row follows whichever permission is still missing; everything turns green when granted. |
| Setup › Microphone | `SetupMicrophoneDemo.swift` | 8 rounded bars driven by the **real** microphone level, mirrored around the centre, resting as small dots in silence, on the soft `SetupBackdrop` gradient. |
| Setup › Shortcut | `SetupKeyChooser.swift`, `SetupKeyboard.swift` | Left: 4 dark keycaps (default key, Right Ctrl, Right Alt, Custom), the chosen one with a blue ring outside its edge. Right half: a **Windows laptop keyboard** (Esc/F-row, Ctrl, Win, Alt, Space, Alt Gr, Ctrl, arrows), black keys in a black well on a dark-grey deck. The chosen key glows blue **around its edge** (350 ms fade), brighter while physically held; the keyboard slides so the key is in view. "Well done" appears under the keycap after the first press. |
| Setup › Alphabet | `SetupAlphabetChoices.swift` | Two cards: big "O‘" with "G‘ Sh Ch" (current) vs "Ö" with "Ğ Ş Ç" (new), plus a one-line example. Selecting only moves the outline; nothing bounces. |
| About you | `QuestionnaireIllustration.swift` | One small scene per question: *discovery*, *voice and notes*, *workspace*, *writing*, *meeting apps* (the app logos), *meeting problems* (checklist). |
| Try it | `TryItPractice.swift` | A real, editable practice text field with live voice-level bars while the user dictates with their own shortcut. |

---

## 6. Shortcuts and dictation behaviour

| Action | Mac | **Windows (proposed)** |
|---|---|---|
| Dictate | fn (default), Right ⌘, Right ⌥, or custom | **Right Alt** (default), Right Ctrl, Ctrl+Win, or custom |
| Paste last transcript | ⌃⌘V | **Ctrl+Alt+V** (Win+V is taken by clipboard history) |
| Toggle sidebar | ⌃⌘S | Ctrl+Shift+S |
| Settings | ⌘, | Ctrl+, |
| New dictionary word / note | ⌘N | Ctrl+N |
| Close Settings / sheets | Esc | Esc |

**Activation modes** (default **Automatic**):
- **Automatic:** hold the key and talk → stops on release. A quick tap (released < 300 ms) starts
  hands-free recording; the next press stops it.
- **Hold:** records only while held (releases < 250 ms are discarded as accidental).
- **Toggle:** press to start, press to stop.

**Recording island:** a small floating pill near the top centre shows waveform / transcribing /
notices ("We didn't catch that", "Copied to clipboard"). Max recording 10 minutes.

**Text insertion** (`Reference/.../TextRules.swift`, Mac `TextInsertionManager.swift`):
1. Insert into whatever field is focused **when the transcript arrives** (re-capture the target).
2. If nothing focused accepts text → copy to clipboard and show "Copied to clipboard".
3. Paste via clipboard (restore the user's clipboard afterwards) or type, per setting.
4. **Spacing:** add a leading space unless the cursor follows whitespace/opening punctuation.
5. **Fit to context** (`TextRules.fitted`): empty field or after `. ! ? …`/newline → capitalise;
   mid-sentence → lowercase the first word unless it is "I", an acronym, mixed case (iPhone), a
   dictionary word or a recognised name; if the **same** sentence continues after the cursor
   (next word lowercase) drop a single trailing full stop. On Windows read the text via UI
   Automation (`TextPattern`); if unavailable, insert unchanged.
6. **Dictionary corrections and snippets** are applied to every transcript before insertion
   (`TextRules.applyingReplacements`). Uzbek alphabet conversion: `UzbekAlphabet.swift`.

---

## 7. Server API (production `https://api.voicelab.uz`)

All calls are account-bound with `Authorization: Bearer <access token>`. JSON uses snake_case.
Port from `Reference/VoiceLabCore/Sources/VoiceLabCore/Networking/` and `Security/`.

### 7.1 Sign-in (OAuth 2 PKCE, browser)
1. `POST /api/v2/auth/desktop/authorizations` with `client_id=voicelab-desktop`, `redirect_uri`,
   `code_challenge` (S256), `state`, installation id, `app_version`, `platform`
   (Mac sends `darwin`; **Windows value must be agreed with backend**, e.g. `win32`).
2. Open the returned `authorization_url` in the browser; receive `voicelab://auth/callback?code&state`
   (or a loopback `http://127.0.0.1:{port}/callback`). Validate `state`.
3. `POST /api/v2/auth/desktop/token` (`grant_type=authorization_code`, `code`, `code_verifier`).
   Store tokens in **Windows Credential Manager** (Mac: Keychain). Refresh on 401 once.
4. `POST /api/v2/auth/desktop/logout` on sign-out.

### 7.2 Endpoints

| Method + path | Purpose |
|---|---|
| `POST /v1/desktop/stt` | multipart: `language=auto`, `audio` file → `{id, revision, text, language, duration_ms}` |
| `GET /v1/desktop/transcriptions?page=N&page_size=50` | History pages |
| `PATCH /v1/desktop/transcriptions/{id}` | Edit a transcript (revisioned) |
| `PUT /v1/desktop/transcriptions/{id}/usage` | App/category context for Desktop usage |
| `GET /v1/desktop/usage` | Plan and minutes (`desktop_stt`) |
| `GET /v1/desktop/statistics?time_zone=…` | Statistics (§7.3) |
| `/v1/desktop/notes` (GET/PUT/DELETE) | Notes sync |
| `GET /v1/desktop/notifications`, `POST …/read` | Inbox |
| `PUT /v1/desktop/push/device` | Push registration |
| `/v1/desktop/onboarding`, `…/completion`, `…/context` | Onboarding progress and questionnaire |

### 7.3 Statistics response
- `days[]`: daily totals **across all devices** (`day`, `language`, `words`, `recordings`,
  `duration_ms`). Use for every total, speed, streak and heatmap.
- `platform_days[]`: the same rows split by `platform` (`desktop` | `ios`). Use **only** for the
  device split. Never add both lists. Missing → older server; don't treat as desktop-only.
- `applications[]`: per-app desktop usage.

---

## 8. Localization
`Localization/strings.json`: `{ key: { lang: value } }`, 677 keys. Keys are the Uzbek source text.
`Localization/by-language/{lang}.json` is the same per language. Languages: uz, en, ru, de, ko,
zh-Hans, hi, es, ar, fr, bn, pt, id, ur, ja, pcm. Arabic and Urdu are right-to-left. Format
placeholders: `%d` (number), `%@` (text), `%1$@` positional.

---

## 9. Open questions for backend / product
1. `platform` value for Windows sign-in, and an `os` / `platform` tag on STT so statistics can show
   Windows separately from Mac (today `platform_days` only knows `desktop` and `ios`).
2. Custom URL scheme `voicelab://` registration on Windows vs loopback redirect.
3. Onboarding illustrations are drawn in code (§5.1); decide whether to also commission static art
   for the installer and Microsoft Store listing.
4. Statistics icon: the Mac uses Apple's SF Symbol `chart.bar.xaxis`, which is licensed for Apple
   platforms only. Windows uses Microsoft's Fluent **Data Bar Vertical** instead (MIT licence,
   `Icons/IconSet/svg/statistics.LICENSE-Fluent-MIT.txt`). Every other icon is the Mac's own.
