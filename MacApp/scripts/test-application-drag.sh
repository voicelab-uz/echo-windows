#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-application-drag.XXXXXX")
trap 'rm -rf "$test_build"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$test_build/ModuleCache" \
  Voicelab/Features/Onboarding/ApplicationBundleDragSource.swift Tests/ApplicationBundleDragRegression.swift \
  -o "$test_build/ApplicationBundleDragRegression"
"$test_build/ApplicationBundleDragRegression"
