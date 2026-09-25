#!/bin/zsh
# Build the Release app and install it into /Applications (a stable path for the login item).
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd PracticesApp && xcodegen generate >/dev/null)
echo "Building practicesctl…"
# The CLI (and MCP server) lives in ~/.practices/bin next to its resource bundle (the Python
# runtime files), with a link in ~/.local/bin for the shell.
(cd PracticesCore && swift build -c release -q)
mkdir -p ~/.practices/bin ~/.local/bin
rm -rf ~/.practices/bin/PracticesCore_PracticesCore.bundle
cp PracticesCore/.build/release/practicesctl ~/.practices/bin/practicesctl
cp -R PracticesCore/.build/release/PracticesCore_PracticesCore.bundle ~/.practices/bin/
ln -sf ~/.practices/bin/practicesctl ~/.local/bin/practicesctl

echo "Building Release…"
xcodebuild -project PracticesApp/Practices.xcodeproj -scheme Practices -configuration Release \
  -derivedDataPath build build 2>&1 | grep -E "error:|\*\* BUILD" || true
APP=build/Build/Products/Release/Practices.app
[ -d "$APP" ] || { echo "Release build not found"; exit 1; }
# Quit the running copy first; an app replaced under itself keeps the old binary mapped.
osascript -e 'tell application id "dev.practices.app" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Practices.app
ditto "$APP" /Applications/Practices.app
open /Applications/Practices.app
echo "Installed: /Applications/Practices.app"
