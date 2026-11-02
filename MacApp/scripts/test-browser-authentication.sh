#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/voicelab-browser.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
localization_bundle="$regression_dir/Localization.bundle"
mkdir -p "$localization_bundle/Contents/Resources"
cat > "$localization_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.echo.browser-localization</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
for catalog in Localizable InfoPlist; do
  xcrun xcstringstool compile "Voicelab/Resources/$catalog.xcstrings" \
    --output-directory "$localization_bundle/Contents/Resources"
done
compiler_flags=(-swift-version 6 -parse-as-library -module-cache-path "$regression_dir/ModuleCache")
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)

xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"

xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift \
  Voicelab/Services/BrowserAuthentication.swift \
  Voicelab/Services/LoopbackAuthenticationCallback.swift \
  Tests/BrowserAuthenticationRegression.swift \
  -o "$regression_dir/BrowserAuthenticationRegression"

ECHO_TEST_LOCALIZATION_BUNDLE="$localization_bundle" "$regression_dir/BrowserAuthenticationRegression" "$@"
