#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-key-hit-testing.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
# Compile the real pure helper without UIKit, allowing quick macOS regression runs.
python3 - "$regression_dir/NativeKeyHitTesting.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOS/VoiceKeyboard/NativeKeySurface.swift').read_text()
helpers = []
for declaration in ('enum NativeKeyboardMetrics {', 'enum NativeKeyHitTesting {', 'struct NativeSpacebarTrackpad {'):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth = 1
    index = opening + 1
    while depth:
        if source[index] == '{': depth += 1
        elif source[index] == '}': depth -= 1
        index += 1
    helpers.append(source[start:index])
Path(sys.argv[1]).write_text('import Foundation\nimport CoreGraphics\n' + '\n'.join(helpers) + '\n')
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$regression_dir/NativeKeyHitTesting.swift" Tests/NativeKeyHitTestingRegression.swift \
  -o "$regression_dir/NativeKeyHitTestingRegression"
"$regression_dir/NativeKeyHitTestingRegression"
