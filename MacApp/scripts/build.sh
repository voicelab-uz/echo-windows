#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Voicelab.xcodeproj -scheme Voicelab \
  -configuration Debug -derivedDataPath build build
print "App: $PWD/build/Build/Products/Debug/Echo.app"
