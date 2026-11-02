#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-key-render.XXXXXX")
output_dir="${ECHO_KEYBOARD_RENDER_OUTPUT:-/tmp/echo-keyboard-style-results}"
mkdir -p "$regression_dir/KeyboardRender.app" "$output_dir"
device_id=$(xcrun simctl create 'Echo Keyboard Regression' com.apple.CoreSimulator.SimDeviceType.iPhone-16e com.apple.CoreSimulator.SimRuntime.iOS-26-5)
trap 'xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true; xcrun simctl delete "$device_id" >/dev/null 2>&1 || true; rm -rf "$regression_dir"' EXIT
python3 - "$regression_dir" <<'PY'
from pathlib import Path
import sys, uuid, plistlib
root=Path(sys.argv[1])
bridge=Path('iOS/Shared/VoiceBridge.swift').read_text().replace('group.uz.voicelab.echo.shared','test.echo.render.'+str(uuid.uuid4()))
(root/'VoiceBridge.swift').write_text(bridge)
(root/'Rendering.swift').write_text(Path('iOS/VoiceKeyboard/NativeKeySurface.swift').read_text()+'\n'+Path('Tests/NativeKeyboardRenderingRegression.swift').read_text())
(root/'KeyboardRender.app/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'uz.voicelab.echo.keyboard-render-regression','CFBundleExecutable':'KeyboardRender','CFBundleName':'KeyboardRender','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'17.0','UILaunchScreen':{}}))
PY
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 6 -parse-as-library -sdk "$sdk" -target arm64-apple-ios17.0-simulator \
 "$regression_dir/VoiceBridge.swift" iOS/VoiceKeyboard/KeyboardModel.swift iOS/VoiceKeyboard/KeyboardAppearance.swift \
 "$regression_dir/Rendering.swift" -o "$regression_dir/KeyboardRender.app/KeyboardRender"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b >/dev/null
xcrun simctl install "$device_id" "$regression_dir/KeyboardRender.app"
xcrun simctl launch "$device_id" uz.voicelab.echo.keyboard-render-regression >/dev/null
container=$(xcrun simctl get_app_container "$device_id" uz.voicelab.echo.keyboard-render-regression data)
for attempt in {1..30}; do
 if [[ -f "$container/Documents/passed.txt" ]]; then
  cp "$container/Documents/"* "$output_dir/"
  cat "$output_dir/passed.txt"
  exit 0
 fi
 sleep 1
done
print -u2 'Rendering regression did not finish; inspect simulator crash logs.'
exit 1
