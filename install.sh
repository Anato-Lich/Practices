#!/bin/zsh
# Build the Release app and install it into /Applications (a stable path for the login item).
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcode-select -p >/dev/null 2>&1 || { echo "Xcode is not set up: install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
for tool in xcodegen uv; do
  command -v $tool >/dev/null 2>&1 && continue
  command -v brew >/dev/null 2>&1 || { echo "$tool is missing and Homebrew is not installed: https://brew.sh"; exit 1; }
  echo "Installing $tool with Homebrew…"
  brew install $tool
done
(cd PracticesApp && xcodegen generate >/dev/null)
echo "Building practicesctl…"
# The CLI (and MCP server) lives in ~/.practices/bin next to its resource bundle (the Python
# runtime files), with a link in ~/.local/bin for the shell.
(cd PracticesCore && swift build -c release -q)
mkdir -p ~/.practices/bin ~/.local/bin
rm -rf ~/.practices/bin/PracticesCore_PracticesCore.bundle
# Remove, then copy: overwriting a signed binary in place keeps the kernel's cached signature
# of the old file, and macOS kills the new one at launch (exit 137).
rm -f ~/.practices/bin/practicesctl
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
# Wait for it to be gone: opening while it quits fails with -600.
for _ in {1..50}; do pgrep -xq Practices || break; sleep 0.1; done
rm -rf /Applications/Practices.app
ditto "$APP" /Applications/Practices.app
open /Applications/Practices.app || true
# Launch Services sometimes drops the open that follows a quit; one retry is enough.
for _ in {1..30}; do pgrep -xq Practices && break; sleep 0.1; done
pgrep -xq Practices || open /Applications/Practices.app
echo "Installed: /Applications/Practices.app"
