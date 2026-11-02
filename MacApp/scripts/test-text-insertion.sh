#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-insertion.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library)
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then
  compiler_flags+=(-disable-sandbox)
fi
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"
xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/Services/TextInsertionMethod.swift Voicelab/Services/TextInsertionManager.swift \
  Voicelab/Services/AccessibilityAccess.swift Voicelab/Services/NativeTextInsertionEnvironment.swift Tests/TextInsertionRegression.swift \
  -o "$regression_dir/TextInsertionRegression"
"$regression_dir/TextInsertionRegression"
