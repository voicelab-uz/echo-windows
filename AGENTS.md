# Instructions for AI agents and developers

This repository contains Echo for Windows, built with .NET 8 and WinUI 3.
The supported solution is `VoiceLabEcho.sln`; application source is in `VoiceLab.WinUI3/`.

- Follow the user's current requirements and the established Windows UI patterns.
- Read `README.md`, `BUILD_INSTRUCTIONS.md`, and the relevant source before changing behavior.
- Keep authentication, transcription, account separation, encrypted storage, and API contracts intact.
- Reuse the app's bundled styles and assets. Preserve font and lexicon licenses and provenance notices.
- Keep generated binaries, installers, local credentials, session files, and test outputs out of Git.
- Do not reintroduce retired projects, external reference source trees, or old progress reports.
- Keep documentation aligned with the actual application and report unverified behavior accurately.
- Never change Windows security policies as part of ordinary builds or installation.

Build with `dotnet build VoiceLabEcho.sln -c Release -p:Platform=x64`.
Run service checks with `dotnet run --project VoiceLab.WinUI3/VoiceLab.SmokeTests/VoiceLab.SmokeTests.csproj -c Release`.
Follow `VoiceLab.WinUI3/RELEASE_VERIFICATION.md` for interactive acceptance checks.
The single-file installer recipe is `VoiceLab.WinUI3/installer/VoiceLab-Echo.iss`.
