#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-transcript-script.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  iOS/VoiceInput/Speech/UzbekTranscriptScript.swift Tests/UzbekTranscriptScriptRegression.swift \
  -o "$regression_dir/UzbekTranscriptScriptRegression"
"$regression_dir/UzbekTranscriptScriptRegression"
