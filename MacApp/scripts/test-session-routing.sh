#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-session.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library -module-cache-path "$regression_dir/module-cache")
sparkle_test_frameworks=${SPARKLE_FRAMEWORK_DIR:?Set SPARKLE_FRAMEWORK_DIR to the folder containing the resolved Sparkle.framework}
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then compiler_flags+=(-disable-sandbox); fi
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"
app_sources=(Voicelab/**/*.swift SharedSession/*.swift)
app_sources=("${(@)app_sources:#Voicelab/VoicelabApp.swift}")
xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  -F "$sparkle_test_frameworks" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$sparkle_test_frameworks" \
  "${app_sources[@]}" Tests/SessionRoutingRegression.swift \
  -o "$regression_dir/SessionRoutingRegression"
"$regression_dir/SessionRoutingRegression"
