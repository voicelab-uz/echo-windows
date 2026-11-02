#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
preview_source="$PWD/Previews/Welcome"
preview_build="$PWD/.build/welcome-preview"
preview_app="$preview_build/EchoWelcomeConcept.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources" "$preview_build/ModuleCache" "$preview_build/Core"

cp "$preview_source/Info.plist" "$preview_app/Contents/Info.plist"
cp -R "$PWD/Voicelab/Features/Onboarding/Experience/Resources/." "$preview_app/Contents/Resources/"
xcrun actool Voicelab/Assets.xcassets \
  --compile "$preview_app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist "$preview_build/asset-info.plist" \
  > "$preview_build/assets.log" 2>&1 || { cat "$preview_build/assets.log"; exit 1; }

export CLANG_MODULE_CACHE_PATH="$preview_build/ModuleCache"
# Reuse the app’s existing authentication, transcription, text, and audio types.
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  -module-name VoiceLabCore -emit-library -static -emit-module \
  -emit-module-path "$preview_build/Core/VoiceLabCore.swiftmodule" \
  Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift \
  -o "$preview_build/Core/libVoiceLabCore.a"

xcrun swiftc \
  -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  -I "$preview_build/Core" -L "$preview_build/Core" -lVoiceLabCore \
  "$preview_source"/*.swift Voicelab/Features/Onboarding/Experience/*.swift \
  Voicelab/Services/AudioRecorder.swift \
  Voicelab/Services/BrowserAuthentication.swift \
  Voicelab/Services/LoopbackAuthenticationCallback.swift \
  Voicelab/Services/MicrophoneCapture.swift \
  Voicelab/Services/MicrophonePCMConverter.swift \
  Voicelab/Services/PCMRecordingWriter.swift \
  Voicelab/Features/Dictation/CameraIslandShape.swift \
  -o "$preview_app/Contents/MacOS/WelcomeConcept"
codesign --force --sign - "$preview_app"
print "App: $preview_app"
