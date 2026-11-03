#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-identity-link.XXXXXX")
trap 'rm -rf "$identity_checks"' EXIT
# Compile the actual client. Only Keychain and URLSession construction are
# adapted so no real credentials, network calls or persistent sessions are used.
python3 - "$identity_checks/EchoAuthClient.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOS/VoiceInput/Speech/EchoAuthClient.swift').read_text()
source = source[:source.index('private struct EchoKeychain {')]
source = source.replace('private let keychain = EchoKeychain()', 'private let keychain = IdentityMemoryKeychain()')
source = source.replace('    private init() {', '''    init(identityTestTransport: URLSession) { transport = identityTestTransport }
    func identityStoredValuesForTesting() -> [String: Data] { keychain.values }
    private init() {''', 1)
source = source.replace('        let loginTransport = URLSession(configuration: config, delegate: EchoRedirectBlocker(), delegateQueue: nil)', '''        config.protocolClasses = transport.configuration.protocolClasses
        let loginTransport = URLSession(configuration: config, delegate: EchoRedirectBlocker(), delegateQueue: nil)''', 1)
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$identity_checks/EchoAuthClient.swift" iOS/VoiceInput/Speech/EchoBillingModels.swift \
  Tests/EchoIdentityLinkRegression.swift -o "$identity_checks/EchoIdentityLinkRegression"
"$identity_checks/EchoIdentityLinkRegression"
