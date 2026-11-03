#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
context_test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-context.XXXXXX")
trap 'rm -rf "$context_test_build"' EXIT
export CLANG_MODULE_CACHE_PATH="$context_test_build/ModuleCache"
xcrun swiftc -swift-version 6 -parse-as-library -module-name VoiceLabCore \
  -emit-library -static -emit-module -emit-module-path "$context_test_build/VoiceLabCore.swiftmodule" \
  Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift -o "$context_test_build/libVoiceLabCore.a"
xcrun swiftc -swift-version 6 -parse-as-library -I "$context_test_build" -L "$context_test_build" -lVoiceLabCore \
  Voicelab/Features/Onboarding/Experience/QuestionnaireModel.swift Tests/QuestionnaireRegression.swift -o "$context_test_build/QuestionnaireRegression"
"$context_test_build/QuestionnaireRegression"
