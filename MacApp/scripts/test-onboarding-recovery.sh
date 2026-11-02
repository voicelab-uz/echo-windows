#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
recovery_build=$(mktemp -d "${TMPDIR:-/tmp}/echo-recovery.XXXXXX")
trap 'rm -rf "$recovery_build"' EXIT
compiler_flags=(-swift-version 6 -parse-as-library)
if [[ "${SWIFT_MACRO_SANDBOX_DISABLED:-0}" == "1" ]]; then
  compiler_flags+=(-disable-sandbox)
fi
xcrun swiftc "${compiler_flags[@]}" \
  Voicelab/Services/AccessibilityAccess.swift \
  Voicelab/Features/Onboarding/Experience/PermissionKind.swift \
  Voicelab/Features/Onboarding/OnboardingJourney.swift \
  Voicelab/Features/Onboarding/OnboardingPermissionsService.swift \
  Tests/OnboardingRecoveryRegression.swift -o "$recovery_build/Recovery"
"$recovery_build/Recovery"
