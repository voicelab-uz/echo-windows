#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
return_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-session-return.XXXXXX")
trap 'rm -rf "$return_build"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library SharedSession/SessionReturnMonitor.swift \
  Tests/SessionReturnRegression.swift -o "$return_build/SessionReturnRegression"
"$return_build/SessionReturnRegression"
