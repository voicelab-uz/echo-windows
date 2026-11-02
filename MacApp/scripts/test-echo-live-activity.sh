#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
live_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-live-activity.XXXXXX")
trap 'rm -rf "$live_checks"' EXIT
# Preserve actual state/lifecycle logic. Only imports of the two unavailable
# iOS frameworks are removed; the test file supplies narrow API boundary adapters.
python3 - "$live_checks" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
for source in ['iOS/Shared/EchoLiveActivityAttributes.swift',
               'iOS/VoiceInput/Keyboard/EchoLiveActivityController.swift']:
    lines = Path(source).read_text().splitlines()
    imports = {'import ActivityKit', '@preconcurrency import ActivityKit', 'import UIKit'}
    (output / Path(source).name).write_text('\n'.join(line for line in lines if line not in imports) + '\n')
PY
if command -v xcrun >/dev/null 2>&1; then compiler=(xcrun swiftc); else compiler=(swiftc); fi
"${compiler[@]}" -swift-version 6 -parse-as-library \
  "$live_checks/EchoLiveActivityAttributes.swift" "$live_checks/EchoLiveActivityController.swift" \
  Tests/EchoLiveActivityControllerRegression.swift -o "$live_checks/EchoLiveActivityControllerRegression"
"$live_checks/EchoLiveActivityControllerRegression"
