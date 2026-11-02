#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
regression_dir=$(mktemp -d "${TMPDIR:-/tmp}/echo-push.XXXXXX")
trap 'rm -rf "$regression_dir"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library -module-cache-path "$regression_dir/module-cache")
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then compiler_flags+=(-disable-sandbox); fi
core_sources=(Packages/VoiceLabCore/Sources/VoiceLabCore/**/*.swift)
xcrun swiftc "${compiler_flags[@]}" -module-name VoiceLabCore \
  -emit-library -emit-module -emit-module-path "$regression_dir/VoiceLabCore.swiftmodule" \
  -o "$regression_dir/libVoiceLabCore.dylib" "${core_sources[@]}"
xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift Voicelab/Services/PushNotificationService.swift \
  Tests/PushNotificationRegression.swift -o "$regression_dir/PushNotificationRegression"
"$regression_dir/PushNotificationRegression"

xcrun swiftc "${compiler_flags[@]}" \
  -I "$regression_dir" -L "$regression_dir" -lVoiceLabCore \
  -Xlinker -rpath -Xlinker "$regression_dir" \
  Voicelab/App/AppLocalization.swift Voicelab/Services/PushNotificationService.swift \
  Voicelab/Services/UpdateNotification.swift Voicelab/Services/UpdateNotificationService.swift \
  Voicelab/Services/NativePushNotificationEnvironment.swift Voicelab/Services/AppNotificationCoordinator.swift \
  Tests/UpdateNotificationRegression.swift -o "$regression_dir/UpdateNotificationRegression"
"$regression_dir/UpdateNotificationRegression"
