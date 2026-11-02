#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PYTHONDONTWRITEBYTECODE=1
swift test --package-path Packages/VoiceLabCore
bash scripts/test-release.sh
python3 Tests/CIReleaseRegression.py
python3 scripts/test-onboarding-resources.py
zsh scripts/test-localization.sh
mkdir -p build
xcodebuild -project Voicelab.xcodeproj -scheme Voicelab -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/ci-check \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build > build/ci-xcode.log 2>&1 || {
        tail -100 build/ci-xcode.log
        exit 1
    }
for arch in arm64 x86_64; do
    xcrun lipo -verify_arch "$arch" build/ci-check/Build/Products/Release/Echo.app/Contents/MacOS/Echo
done
