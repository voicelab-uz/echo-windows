#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

test_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-setup-shortcut.XXXXXX")
trap 'rm -rf "$test_build"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$test_build/ModuleCache" \
  Voicelab/Features/Onboarding/Experience/SetupShortcutValidation.swift Tests/SetupShortcutRegression.swift \
  -o "$test_build/SetupShortcutRegression"
"$test_build/SetupShortcutRegression"
