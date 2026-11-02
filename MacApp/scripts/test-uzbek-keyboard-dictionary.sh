#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-keyboard.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  iOS/VoiceKeyboard/UzbekKeyboardDictionary.swift Tests/UzbekKeyboardDictionaryRegression.swift \
  -o "$regression_dir/UzbekKeyboardDictionaryRegression"
"$regression_dir/UzbekKeyboardDictionaryRegression"
