#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
./scripts/build-welcome-preview.sh
preview_build="$PWD/.build/welcome-preview"
context_review="$preview_build/context-review"
context_app="$context_review/EchoContextReview.app"
mkdir -p "$context_app/Contents/MacOS" "$context_app/Contents/Resources"

# Substitute only the app entry point. All screen components are shared with onboarding.
python3 - <<'PY'
from pathlib import Path
import plistlib

review = Path('.build/welcome-preview/context-review')
source = Path('Previews/Welcome/WelcomeConcept.swift').read_text()
source = source.replace('private struct WelcomeProgress', 'struct WelcomeProgress')
source = source.replace('Echo — Welcome concept', 'Echo — Questionnaire design preview')
source = source.replace('            WelcomeConcept()', '            QuestionnaireReview()')
(review / 'WelcomeConcept.swift').write_text(source)
info = plistlib.loads(Path('Previews/Welcome/Info.plist').read_bytes())
info['CFBundleIdentifier'] = 'dev.echo.context-review'
info['CFBundleName'] = 'Echo Context Review'
(review / 'EchoContextReview.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY

cp -R "$preview_build/EchoWelcomeConcept.app/Contents/Resources/." "$context_app/Contents/Resources/"
preview_files=(Previews/Welcome/*.swift)
preview_files=(${preview_files:#Previews/Welcome/WelcomeConcept.swift})
export CLANG_MODULE_CACHE_PATH="$preview_build/ModuleCache"
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  -I "$preview_build/Core" -L "$preview_build/Core" -lVoiceLabCore \
  "$context_review/WelcomeConcept.swift" Previews/QuestionnaireReview/QuestionnaireReview.swift "${preview_files[@]}" Voicelab/Features/Onboarding/Experience/*.swift \
  Voicelab/Services/AudioRecorder.swift Voicelab/Services/BrowserAuthentication.swift \
  Voicelab/Services/LoopbackAuthenticationCallback.swift Voicelab/Services/MicrophoneCapture.swift \
  Voicelab/Services/MicrophonePCMConverter.swift Voicelab/Services/PCMRecordingWriter.swift \
  Voicelab/Features/Dictation/CameraIslandShape.swift -o "$context_app/Contents/MacOS/WelcomeConcept"
codesign --force --sign - "$context_app"
print "App: $context_app"
