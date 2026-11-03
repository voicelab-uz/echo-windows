# Instructions for AI agents and developers

This repo is **Echo for Windows** (.NET 8, WinUI 3), in `VoiceLab.WinUI3/`. It uses
**Echo for macOS**, whose complete source is in [`MacApp/`](MacApp/), as its reference,
while honoring explicit user-requested Windows changes.

Before changing any UI or behaviour, read:
1. [`MAC_TO_WINDOWS.md`](MAC_TO_WINDOWS.md): how to port, the SwiftUI → WinUI table, and which Mac
   file each screen comes from.
2. [`DesignHandoff/HANDOFF.md`](DesignHandoff/HANDOFF.md): the spec for brand, layout, screens,
   onboarding, shortcuts and the server API.
3. The matching Swift files in `MacApp/`, completely.

Rules:
- The Mac app is the source of truth for reference behavior and API contracts. Follow
  explicit user requests when Windows behavior or layout differs.
- Copy exact values (sizes, colours, fonts, radii, animation timings, strings) from the Swift code.
  Don't invent new layouts, colours or copy.
- Use only assets from `DesignHandoff/` (icons, colours, fonts, localization). Onboarding
  illustrations are drawn in code (HANDOFF §5.1), not images.
- Port `VoiceLabCore` logic together with its tests; Windows tests must give the same results.
- Never edit `MacApp/`. Refresh it with `DesignHandoff/Tools/sync-mac-source.sh /path/to/echo`.
- Consult the Windows release limits in `MAC_TO_WINDOWS.md`; record new platform
  differences in HANDOFF §9.

Build the root `VoiceLabEcho.sln` and run `VoiceLab.WinUI3/VoiceLab.SmokeTests` for service checks.
Keep generated packages in ignored `artifacts/`. Do not reintroduce the retired WPF projects
or old progress reports; Git history preserves the committed legacy implementation.
