#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-profile.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  iOS/VoiceInput/Speech/EchoAuthClient.swift Tests/EchoProfileAPIRegression.swift \
  -o "$regression_dir/EchoProfileAPIRegression"
"$regression_dir/EchoProfileAPIRegression"
