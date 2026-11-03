#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Extract the real ObjC nullability boundary for a runnable macOS regression.
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile
source = Path('iOS/VoiceKeyboard/KeyboardViewController.swift').read_text()
assert 'textDocumentProxy.documentIdentifier' not in source, 'Direct UUID getter reintroduces the nil bridge crash'
start = source.index('enum KeyboardDocumentIdentity {')
with tempfile.TemporaryDirectory(prefix='echo-document-identity-') as temp:
    directory = Path(temp)
    helper = directory / 'KeyboardDocumentIdentity.swift'
    helper.write_text('import Foundation\n' + source[start:])
    binary = directory / 'regression'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(helper), 'Tests/KeyboardDocumentIdentityRegression.swift', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
PY
