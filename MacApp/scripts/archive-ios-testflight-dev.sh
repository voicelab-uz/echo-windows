#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# A Release archive pointed at the development API. Normal Release stays production.
build_number=${1:?Usage: archive-ios-testflight-dev.sh BUILD_NUMBER [ARCHIVE_PATH]}
archive_path=${2:-/tmp/Echo-Dev-TestFlight.xcarchive}
xcodebuild -project iOS/Echo.xcodeproj -scheme Echo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=L5FXR2YA4Q \
  CURRENT_PROJECT_VERSION="$build_number" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ECHO_DEV_ENVIRONMENT' archive
