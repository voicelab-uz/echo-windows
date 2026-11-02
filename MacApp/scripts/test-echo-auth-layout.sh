#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
layout_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-auth-layout.XXXXXX")
trap 'rm -rf "$layout_checks"' EXIT
# Measure actual production SwiftUI subviews offscreen; no SDK sign-in or UI clicks.
python3 - "$layout_checks/EchoAuthLayout.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOS/VoiceInput/App/OnboardingView.swift').read_text()
start = source.index('private struct EchoAuthStatusRegion: View')
end = source.index('/// Reuse Google', start)
source = source[start:end].replace('private struct EchoAuthStatusRegion', 'struct EchoAuthStatusRegion').replace('private struct EchoGoogleSignInLabel', 'struct EchoGoogleSignInLabel')
Path(sys.argv[1]).write_text('import SwiftUI\n' + source)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$layout_checks/EchoAuthLayout.swift" Tests/EchoAuthLayoutRegression.swift \
  -o "$layout_checks/EchoAuthLayoutRegression"
"$layout_checks/EchoAuthLayoutRegression"
