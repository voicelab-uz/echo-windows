#!/bin/zsh
# Opt-in network qualification against the public test channel; never installs.
set -euo pipefail
cd "${0:A:h:h}"
: ${SPARKLE_FRAMEWORK_DIR:?Set the folder containing the pinned Sparkle.framework}
: ${ECHO_SPARKLE_PUBLIC_KEY:?Set the trusted public update key}
: ${ECHO_UPDATE_FEED_URL:?Set the public test feed URL}
: ${ECHO_EXPECTED_UPDATE_BUILD:?Set the build expected in the public feed}
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/echo-feed-probe.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT
export ECHO_FEED_PROBE_DIRECTORY="$probe_directory"
python3 - <<'PY'
import os, plistlib, re, uuid
from pathlib import Path
from urllib.parse import urlparse
url = os.environ['ECHO_UPDATE_FEED_URL']
parts = urlparse(url)
assert parts.scheme == 'https' and parts.hostname and not parts.username and not parts.password
assert not parts.query and not parts.fragment and parts.path.endswith('/test/appcast.xml')
app = Path(os.environ['ECHO_FEED_PROBE_DIRECTORY']) / 'Probe.app/Contents'
(app / 'MacOS').mkdir(parents=True)
installed = os.environ.get('ECHO_INSTALLED_PROBE_BUILD', '1')
assert re.fullmatch(r'[1-9][0-9]{0,17}', installed)
info = dict(CFBundleIdentifier='uz.voicelab.tests.feed.' + uuid.uuid4().hex,
            CFBundleName='Echo feed probe', CFBundleExecutable='Probe', CFBundlePackageType='APPL',
            CFBundleVersion=installed, CFBundleShortVersionString='1.0', LSMinimumSystemVersion='14.0',
            SUFeedURL=url, SUPublicEDKey=os.environ['ECHO_SPARKLE_PUBLIC_KEY'],
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
            SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
            SUSignedFeedFailureExpirationInterval=0, SUEnableSystemProfiling=False)
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -swift-version 6 -parse-as-library \
    -F "$SPARKLE_FRAMEWORK_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$SPARKLE_FRAMEWORK_DIR" \
    Tests/LiveUpdateFeedProbe.swift -o "$probe_directory/Probe.app/Contents/MacOS/Probe"
"$probe_directory/Probe.app/Contents/MacOS/Probe"
