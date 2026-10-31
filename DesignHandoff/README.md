# Echo design handoff for Windows

Assets, copy and specs exported from **Echo for macOS** so the Windows app can match it exactly.

Start with **[HANDOFF.md](HANDOFF.md)**: brand, layout, every screen, onboarding, shortcuts, text
rules and the server API.

```
DesignHandoff/
├── HANDOFF.md                 full spec (start here)
├── Brand/
│   ├── colors.json            every colour, light + dark
│   ├── Logo/                  app icon 16…1024 px, logo 512 px
│   └── Fonts/                 Manrope (onboarding), OFL licence
├── Icons/
│   ├── app-icon.ico           16, 20, 24, 32, 40, 48, 64, 128, 256
│   ├── tray-icon-light-taskbar(.ico, -recording.ico, -16/-32.png)
│   ├── tray-icon-dark-taskbar (.ico, -recording.ico, -16/-32.png)
│   ├── logo.png               sidebar header, 256 px
│   ├── Navigation/            home, statistics, vocabulary, notes, getting-started, settings
│   │                          ×  light / dark / @2x / active-light / active-dark
│   ├── IconSet/               every workspace icon: svg/, png-light/, png-dark/ (24 + 48)
│   └── ThirdPartyApps/        app logos used in the onboarding questionnaire
├── Onboarding/
│   ├── Copy/                  onboarding text, 16 languages (JSON)
│   └── *.png                  fallbacks only — illustrations are drawn in code (HANDOFF.md §5.1)
├── EmptyStates/               no-history, no-notes, no-vocabulary (light + -dark)
├── Localization/              strings.json + by-language/*.json (677 strings × 16 languages)
├── Reference/VoiceLabCore/    the Mac's shared Swift core and tests (API, auth, text rules)
├── Reference/Onboarding/      the Mac's onboarding screens + illustration drawing code
└── Tools/                     scripts that regenerate these assets from the Mac app
```

All icons are the ones the Mac app uses (its SVG icon set and its menu-bar mark for the tray), except
Statistics: the Mac's Apple-only symbol is replaced by Microsoft's Fluent "Data Bar Vertical" (MIT).
Onboarding illustrations are not images: draw them in code from the Mac source (HANDOFF.md §5.1).

When the Mac assets change, regenerate them with [Tools/](Tools/README.md).
