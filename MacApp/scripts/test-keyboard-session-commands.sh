#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-keyboard-session.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
# Exercise actual bridge/model policy, presence, and handoff races while isolating
# UserDefaults from the app. The synchronous harness deliberately withholds queued
# notifications so tap-time refresh is tested rather than polling luck.
python3 - "$regression_dir/VoiceBridge.swift" <<'PY'
from pathlib import Path
import sys
import uuid
source = Path('iOS/Shared/VoiceBridge.swift').read_text()
isolated = 'test.echo.keyboard.' + str(uuid.uuid4())
source = source.replace('group.uz.voicelab.echo.shared', isolated)
source = source.replace('uz.voicelab.echo.command', isolated + '.command')
source = source.replace('uz.voicelab.echo.state', isolated + '.state')
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$regression_dir/VoiceBridge.swift" iOS/VoiceKeyboard/KeyboardModel.swift \
  Tests/KeyboardSessionCommandRegression.swift \
  -o "$regression_dir/KeyboardSessionCommandRegression"
"$regression_dir/KeyboardSessionCommandRegression"
