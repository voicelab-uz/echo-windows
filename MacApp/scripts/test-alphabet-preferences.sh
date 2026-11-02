#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/voicelab-alphabet.XXXXXX")
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
  Voicelab/App/AppLocalization.swift Voicelab/App/Preferences.swift Voicelab/Services/TextInsertionMethod.swift Voicelab/Services/DictationActivationMode.swift \
  Voicelab/Services/DictationShortcut.swift Tests/AlphabetPreferencesRegression.swift \
  -o "$regression_dir/AlphabetPreferencesRegression"
"$regression_dir/AlphabetPreferencesRegression"
if [[ "${1:-}" == "--preferences-only" ]]; then exit 0; fi

xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift Voicelab/App/Preferences.swift Voicelab/Services/TextInsertionMethod.swift Voicelab/Services/DictationActivationMode.swift \
  Voicelab/App/LibraryModel.swift Voicelab/Services/DictationShortcut.swift \
  Voicelab/Services/AudioRecorder.swift Voicelab/Services/MicrophoneCapture.swift \
  Voicelab/Services/MicrophonePCMConverter.swift Voicelab/Services/PCMRecordingWriter.swift \
  Voicelab/Services/TextInsertion.swift Voicelab/Services/TextInsertionManager.swift \
  Voicelab/Services/AccessibilityAccess.swift Voicelab/Services/NativeTextInsertionEnvironment.swift Voicelab/Features/Dictation/DictationModel.swift \
  Tests/DictationAlphabetRegression.swift \
  -o "$regression_dir/DictationAlphabetRegression"
"$regression_dir/DictationAlphabetRegression"
