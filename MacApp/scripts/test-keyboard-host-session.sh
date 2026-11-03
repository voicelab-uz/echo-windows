#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
host_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-keyboard-host.XXXXXX")
trap 'rm -rf "$host_checks"' EXIT
# Compile the real host/bridge. UIKit and audio platform boundaries are replaced;
# Foundation notifications and the session policy run normally with isolated defaults.
python3 - "$host_checks" <<'PY'
from pathlib import Path
import sys, uuid
output = Path(sys.argv[1])
bridge = Path('iOS/Shared/VoiceBridge.swift').read_text()
isolated = 'test.echo.host.' + str(uuid.uuid4())
bridge = bridge.replace('group.uz.voicelab.echo.shared', isolated)
bridge = bridge.replace('uz.voicelab.echo.command', isolated + '.command')
bridge = bridge.replace('uz.voicelab.echo.state', isolated + '.state')
(output / 'VoiceBridge.swift').write_text(bridge)
host = Path('iOS/VoiceInput/Keyboard/KeyboardSessionHost.swift').read_text()
host = '\n'.join(line for line in host.splitlines() if line not in ('import UIKit', 'import AVFAudio')) + '\n'
(output / 'KeyboardSessionHost.swift').write_text(host + Path('Tests/KeyboardHostSessionRegression.swift').read_text())
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$host_checks/VoiceBridge.swift" "$host_checks/KeyboardSessionHost.swift" \
  -o "$host_checks/KeyboardHostSessionRegression"
"$host_checks/KeyboardHostSessionRegression"
