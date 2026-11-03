#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
update_test_frameworks=${SPARKLE_FRAMEWORK_DIR:?Set SPARKLE_FRAMEWORK_DIR to the folder containing the resolved Sparkle.framework}
update_test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-update-lifecycle.XXXXXX")
trap 'rm -rf "$update_test_build"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library -module-cache-path "$update_test_build/module-cache")
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then compiler_flags+=(-disable-sandbox); fi
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore -emit-library -static -emit-module \
    -emit-module-path "$update_test_build/VoiceLabCore.swiftmodule" \
    Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift -o "$update_test_build/libVoiceLabCore.a"
mkdir -p "$update_test_build/UpdateLifecycle.app/Contents/MacOS"
cat > "$update_test_build/UpdateLifecycle.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>uz.voicelab.tests.update-lifecycle</string>
<key>CFBundleName</key><string>UpdateLifecycle</string><key>CFBundleExecutable</key><string>UpdateLifecycle</string>
<key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc "${compiler_flags[@]}" -I "$update_test_build" -L "$update_test_build" -lVoiceLabCore \
    -F "$update_test_frameworks" -framework Sparkle -Xlinker -rpath -Xlinker "$update_test_frameworks" \
    Voicelab/Services/UpdateNotification.swift Voicelab/Services/AppUpdatePhase.swift Voicelab/Services/AppUpdateChecker.swift \
    Voicelab/Services/UpdateRestartMessages.swift Tests/UpdateLifecycleRegression.swift \
    -o "$update_test_build/UpdateLifecycle.app/Contents/MacOS/UpdateLifecycle"
"$update_test_build/UpdateLifecycle.app/Contents/MacOS/UpdateLifecycle"
xcrun swiftc "${compiler_flags[@]}" SharedSession/UpdateInstallationLease.swift \
    Tests/UpdateInstallationLeaseRegression.swift -o "$update_test_build/LeaseRegression"
"$update_test_build/LeaseRegression"
