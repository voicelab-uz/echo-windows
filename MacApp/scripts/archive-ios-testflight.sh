#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Production is the default for both Debug and Release builds.
build_number=${1:?Usage: archive-ios-testflight.sh BUILD_NUMBER [ARCHIVE_PATH]}
archive_path=${2:-/tmp/Echo-TestFlight.xcarchive}
xcodebuild -project iOS/Echo.xcodeproj -scheme Echo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=L5FXR2YA4Q \
  CURRENT_PROJECT_VERSION="$build_number" archive
