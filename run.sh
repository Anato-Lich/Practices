#!/bin/zsh
# Build and launch Practices without changing xcode-select.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd PracticesApp && xcodegen generate >/dev/null)
xcodebuild -project PracticesApp/Practices.xcodeproj -scheme Practices -configuration Debug \
  -derivedDataPath build build 2>&1 | grep -E "error:|BUILD"
open build/Build/Products/Debug/Practices.app
