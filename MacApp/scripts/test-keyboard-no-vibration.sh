#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# User requirement: no custom keyboard vibration, including emoji/menu/trackpad
# paths and previously enabled preferences. Keep the OS-controlled input click.
python3 - <<'PY'
from pathlib import Path
import re
root = Path('iOS/VoiceKeyboard')
forbidden = re.compile(
    r'\b(?:UI(?:Impact|Selection|Notification)?FeedbackGenerator|CHHaptic\w*|'
    r'AudioServices\w*|SystemSoundID|kSystemSoundID_Vibrate|AVAudioPlayer)\b'
    r'|\.sensoryFeedback\s*\(|\bvibrate\s*\('
    r'|\bimport\s+CoreHaptics\b|keyHapticsEnabled|echo\.keyboard\.haptics'
)
files = list(root.rglob('*.swift'))
assert files, 'Keyboard source missing'
violations = []
for path in files:
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if forbidden.search(line):
            violations.append(f'{path}:{line_number}: custom vibration/sound actuator or obsolete preference')
assert not violations, '\n'.join(violations)
surface = (root / 'NativeKeySurface.swift').read_text()
assert re.search(r'UIDevice\.current\.playInputClick\(\)', surface), 'Keep standard OS-controlled keyboard clicks'
print('Keyboard has no custom vibration or sound playback; standard OS input clicks retained')
PY
