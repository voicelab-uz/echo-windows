#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/test-localization.py
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-localization.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library)
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then
  compiler_flags+=(-disable-sandbox)
fi
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"
mkdir -p "$regression_dir/Translations.bundle"
xcrun xcstringstool compile Voicelab/Resources/Localizable.xcstrings \
  --output-directory "$regression_dir/Translations.bundle"
xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift Tests/LocalizationRegression.swift \
  -o "$regression_dir/LocalizationRegression"
"$regression_dir/LocalizationRegression" "$regression_dir/Translations.bundle" \
  Voicelab/Resources/Localizable.xcstrings
