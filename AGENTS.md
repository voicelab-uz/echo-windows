# Instructions for AI agents and developers

This repo is **Echo for Windows** (.NET 8, WPF). It must look, move and behave like
**Echo for macOS**, whose complete source is in [`MacApp/`](MacApp/).

Before changing any UI or behaviour, read:
1. [`MAC_TO_WINDOWS.md`](MAC_TO_WINDOWS.md): how to port, the SwiftUI → WPF table, and which Mac
   file each screen comes from.
2. [`DesignHandoff/HANDOFF.md`](DesignHandoff/HANDOFF.md): the spec for brand, layout, screens,
   onboarding, shortcuts and the server API.
3. The matching Swift files in `MacApp/`, completely.

Rules:
- The Mac app is the source of truth. If an older document in this repo (`FINAL_SUMMARY.md`,
  `PROJECT_COMPLETE.md`, `UI_IMPROVEMENTS.md`, …) disagrees with the Mac code, follow the Mac.
- Copy exact values (sizes, colours, fonts, radii, animation timings, strings) from the Swift code.
  Don't invent new layouts, colours or copy.
- Use only assets from `DesignHandoff/` (icons, colours, fonts, localization). Onboarding
  illustrations are drawn in code (HANDOFF §5.1), not images.
- Port `VoiceLabCore` logic together with its tests; Windows tests must give the same results.
- Never edit `MacApp/`. Refresh it with `DesignHandoff/Tools/sync-mac-source.sh /path/to/echo`.
- Differences forced by Windows are listed in `MAC_TO_WINDOWS.md` §5; record any new ones in
  HANDOFF §9.
