#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
billing_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-billing.XXXXXX")
trap 'rm -rf "$billing_checks"' EXIT
# Test the actual public request builder without importing keychain/Google SDKs.
python3 - "$billing_checks/PublicBillingRequest.swift" <<'PYCODE'
from pathlib import Path
import sys
source = Path('iOS/VoiceInput/Speech/EchoAuthClient.swift').read_text()
def method(marker):
    start = source.index(marker)
    opening = source.index('{', start)
    level = 1
    end = opening + 1
    while level:
        if source[end] == '{': level += 1
        elif source[end] == '}': level -= 1
        end += 1
    return source[start:end]
methods = method('    static func publicBillingPricingRequest()') + '\n' + method('    func billingRequest(')
Path(sys.argv[1]).write_text('import Foundation\nextension EchoAuthClient {\n' + methods + '\n}\n')
PYCODE
xcrun swiftc -swift-version 6 -parse-as-library \
  iOS/VoiceInput/Speech/EchoBillingModels.swift Tests/EchoBillingModelsRegression.swift \
  "$billing_checks/PublicBillingRequest.swift" \
  -o "$billing_checks/EchoBillingModelsRegression"
"$billing_checks/EchoBillingModelsRegression" "$@"
