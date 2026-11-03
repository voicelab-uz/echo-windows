#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-setup-meter.XXXXXX")
trap 'rm -rf "$test_build"' EXIT
export CLANG_MODULE_CACHE_PATH="$test_build/ModuleCache"
xcrun swiftc -swift-version 6 -parse-as-library -module-name VoiceLabCore \
  -emit-library -static -emit-module -emit-module-path "$test_build/VoiceLabCore.swiftmodule" \
  Packages/VoiceLabCore/Sources/VoiceLabCore/Domain/MicrophoneMeter.swift \
  Packages/VoiceLabCore/Sources/VoiceLabCore/Domain/DictationLevelMeter.swift \
  -o "$test_build/libVoiceLabCore.a"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$test_build" -L "$test_build" -lVoiceLabCore \
  Voicelab/Services/MicrophoneCapture.swift Voicelab/Services/MicrophonePCMConverter.swift \
  Voicelab/Services/PCMRecordingWriter.swift \
  Voicelab/Features/Onboarding/Experience/SetupMicrophoneMonitor.swift Tests/SetupMicrophoneRegression.swift \
  -o "$test_build/SetupMicrophoneRegression"
"$test_build/SetupMicrophoneRegression"
