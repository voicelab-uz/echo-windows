#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
trial_test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-try-it.XXXXXX")
trap 'rm -rf "$trial_test_build"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library)
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then
  compiler_flags+=(-disable-sandbox)
fi
export CLANG_MODULE_CACHE_PATH="$trial_test_build/ModuleCache"
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -static -emit-module -emit-module-path "$trial_test_build/VoiceLabCore.swiftmodule" \
  Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift \
  -o "$trial_test_build/libVoiceLabCore.a"
xcrun swiftc "${compiler_flags[@]}" \
  -I "$trial_test_build" -L "$trial_test_build" -lVoiceLabCore \
  Voicelab/Services/DictationShortcut.swift Voicelab/App/AppLocalization.swift \
  Voicelab/App/Preferences.swift Voicelab/App/LibraryModel.swift \
  Voicelab/Services/TextInsertionMethod.swift Voicelab/Services/DictationActivationMode.swift Voicelab/Services/TextInsertion.swift \
  Voicelab/Services/TextInsertionManager.swift Voicelab/Services/NativeTextInsertionEnvironment.swift \
  Voicelab/Services/AccessibilityAccess.swift \
  Voicelab/Features/Dictation/DictationModel.swift Voicelab/Features/Dictation/IslandRecordingSession.swift \
  Voicelab/Services/MicrophoneCapture.swift Voicelab/Services/MicrophonePCMConverter.swift \
  Voicelab/Services/PCMRecordingWriter.swift Voicelab/Services/AudioRecorder.swift \
  Voicelab/Services/BrowserAuthentication.swift Voicelab/Services/LoopbackAuthenticationCallback.swift \
  Voicelab/Features/Onboarding/Experience/SetupShortcutValidation.swift Previews/Welcome/TryItSession.swift Voicelab/Features/Onboarding/Experience/TryItServing.swift \
  Voicelab/Features/Onboarding/Experience/TryItModel.swift Tests/TryItRegression.swift \
  -o "$trial_test_build/TryItRegression"
"$trial_test_build/TryItRegression"
