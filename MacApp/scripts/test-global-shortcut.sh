#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
shortcut_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-global-shortcut.XXXXXX")
trap 'rm -rf "$shortcut_build"' EXIT
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc -swift-version 6 -parse-as-library -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$shortcut_build/VoiceLabCore.swiftmodule" \
  -o "$shortcut_build/libVoiceLabCore.dylib" "${core_sources[@]}"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$shortcut_build" -L "$shortcut_build" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$shortcut_build" \
  Voicelab/Services/{GlobalShortcut,DictationShortcut,FnKeyPolicy,AccessibilityAccess}.swift Voicelab/App/AppLocalization.swift \
  Tests/GlobalShortcutRegression.swift -o "$shortcut_build/GlobalShortcutRegression"
"$shortcut_build/GlobalShortcutRegression"
