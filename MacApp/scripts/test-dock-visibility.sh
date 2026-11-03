#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/voicelab-dock.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library)
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"
xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift Voicelab/App/Preferences.swift \
  Voicelab/Services/TextInsertionMethod.swift Voicelab/Services/DictationActivationMode.swift Voicelab/Services/DictationShortcut.swift \
  Voicelab/Services/MainWindowPresenter.swift Tests/DockVisibilityRegression.swift \
  -o "$regression_dir/DockVisibilityRegression"
"$regression_dir/DockVisibilityRegression"
