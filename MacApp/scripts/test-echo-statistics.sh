#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
statistics_checks=$(mktemp -d "${TMPDIR:-/tmp}/echo-statistics.XXXXXX")
trap 'rm -rf "$statistics_checks"' EXIT
# Compile the actual DTO, independent of keychain, Google SDKs and UI frameworks.
python3 - "$statistics_checks/EchoStatistics.swift" <<'PY'
from pathlib import Path
import sys
source = Path('iOS/VoiceInput/Speech/EchoAuthClient.swift').read_text()
start = source.index('struct EchoStatistics:')
end = source.index('\n/// Account dictations', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end] + '\n')
PY
if command -v xcrun >/dev/null 2>&1; then compiler=(xcrun swiftc); else compiler=(swiftc); fi
"${compiler[@]}" -swift-version 6 -parse-as-library \
  "$statistics_checks/EchoStatistics.swift" Tests/EchoStatisticsRegression.swift \
  -o "$statistics_checks/EchoStatisticsRegression"
"$statistics_checks/EchoStatisticsRegression"
