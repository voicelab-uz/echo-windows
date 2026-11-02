# Echo 2.0.0 (108) stable release

Published October 29, 2026 from clean source `4c49d6fd832847327877b9f5bbbfcce4e9e9481b`.

- [Universal DMG](https://github.com/voicelab-uz/echo-releases/releases/download/stable-2.0.0-108/Echo-2.0.0-108-universal.dmg), Apple Silicon and Intel, macOS 14 or newer.
- [Signed stable feed](https://raw.githubusercontent.com/voicelab-uz/echo-releases/main/stable/appcast.xml).
- Immutable GitHub release `stable-2.0.0-108` (ID `427227726`), DMG asset `686451277`.
- DMG size: 12,412,260 bytes. SHA-256: `6f19ca558c0a05ca916262bd3bae82256841e37064869b15448ea98e170cf070`.
- App notarization: `bdc42363-272d-4a48-91e7-1c0a81a76baf`.
- DMG notarization: `1d5fa067-d8e2-421e-8a89-321abeff5315`.
- Signing team `FWCSVFT76D`, bundle ID `uz.voicelab.desktop`.

Publication verified every planned public asset against the prepared local bytes before promoting the signed feed. The artifact is a fresh stable build, not a relabeled test DMG. It contains the final four-pose installer, Echo disk icon and separated VoiceLab credit.

## Download and installation evidence

A fresh Chrome download matched the published SHA-256 and retained quarantine. Gatekeeper accepted the notarized DMG and app. Both executable architectures, strict deep signature verification, staples, mounted Finder layout and embedded stable feed passed inspection.

The installed build 107 was backed up before replacement. Native Finder file-copy automation installed build 108 at `/Applications/Echo.app`; the synthetic drag did not reliably complete and is not counted as a successful physical drag-install test. Account restoration succeeded, and the user confirmed that clicking Echo's Dock icon opens its normal workspace.

This automated copy retained macOS App Translocation: the running app was on a temporary read-only security volume. Sparkle correctly rejected updating it with `SURunningTranslocated` (1005), before reading the update feed. Dock activation does not remove that restriction. Do not strip quarantine. The user then completed the normal Finder drag to Applications, chose Replace, reopened Echo and confirmed Check for Updates reports up to date. Process inspection confirmed the running executable is `/Applications/Echo.app/Contents/MacOS/Echo`, outside App Translocation. The subsequent notification change also gives the translocation condition specific installation guidance instead of generic retry text.

## Public website

Frontend commit `4e7701b6fb989a3730e81b7f0a0ee651d89bf0e8`, production workflow `40776029004`, release `ci-4e7701b6fb98-40776029004-1`, serves this exact DMG at both `echo.voicelab.uz` and `voicelab.uz/download`. Both pages returned HTTP 200 with the expected deployment ID. macOS labels identify the universal build; existing Linux downloads are preserved. Release discovery has bounded requests and a verified pinned 108 fallback.

## Update behavior in 108

Settings > General and the menu-bar menu expose update status and Check for Updates. Manual checks use Sparkle's native UI. Scheduled checks/downloads are quiet; a verified staged update installs on an ordinary quit. Native update banners and APNs category preferences are separate unreleased changes, not features of build 108.

The [test release record](UPDATE_TEST_RELEASE.md) documents real 106-to-107 installation on ordinary quit, fresh Google sign-in, and the user's successful physical Fn recording/transcription/text-insertion check. Build 108 uses the same app source. Physical Intel/macOS 14 runtime and destructive interruption scenarios were not exercised on this Mac. No guarantee of crash-free operation or automatic rollback after an app-launch failure is claimed.
