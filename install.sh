#!/bin/zsh
# Build the Release app and install it into /Applications (a stable path for the login item),
# and the CLI into $PRACTICES_HOME/bin (default ~/.practices/bin). Both replace what is installed.
# This is the from-source path: the app also carries the CLI in Contents/Helpers and installs it
# itself («Начало» / «Настройка»), which is how a DMG user gets it.
set -e
cd "$(dirname "$0")"
HOME_DIR=${PRACTICES_HOME:-$HOME/.practices}
BIN=$HOME_DIR/bin
echo "This replaces:"
echo "  $BIN/practicesctl, its resource bundle and uv, linked from ~/.local/bin/practicesctl"
echo "  /Applications/Practices.app — a running copy is quit and started again"
echo "Your catalogue, secrets and local.yaml in $HOME_DIR are not touched."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcode-select -p >/dev/null 2>&1 || { echo "Xcode is not set up: install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
# uv is not needed here: the build puts the pinned one into Contents/Helpers (DECISIONS 40).
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "xcodegen is missing and Homebrew is not installed: https://brew.sh"; exit 1; }
  echo "Installing xcodegen with Homebrew…"
  brew install xcodegen
fi
(cd PracticesApp && xcodegen generate >/dev/null)

echo "Building Release…"
xcodebuild -project PracticesApp/Practices.xcodeproj -scheme Practices -configuration Release \
  -derivedDataPath build build 2>&1 | grep -E "error:|\*\* BUILD" || true
APP=build/Build/Products/Release/Practices.app
HELPERS=$APP/Contents/Helpers
[ -x "$HELPERS/practicesctl" ] && [ -x "$HELPERS/uv" ] || { echo "Release build not found, or its Contents/Helpers is incomplete"; exit 1; }
# The CLI (and MCP server) lives in $BIN next to its resource bundle (the Python runtime files)
# and uv, with a link in ~/.local/bin for the shell. Copied from the app's Helpers, the same
# files the app compares at launch, so it has nothing to reinstall.
mkdir -p "$BIN" ~/.local/bin
# Remove, then copy: overwriting a signed binary in place keeps the kernel's cached signature
# of the old file, and macOS kills the new one at launch (exit 137).
rm -rf "$BIN/practicesctl" "$BIN/PracticesCore_PracticesCore.bundle" "$BIN/uv"
cp "$HELPERS/practicesctl" "$HELPERS/uv" "$BIN/"
cp -R "$HELPERS/PracticesCore_PracticesCore.bundle" "$BIN/"
ln -sf "$BIN/practicesctl" ~/.local/bin/practicesctl

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
# Refresh Launch Services so the icon is registered.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Practices.app >/dev/null 2>&1 || true
# Desktop alias, replacing an existing one.
osascript -e 'tell application "Finder"
  if exists alias file "Practices" of desktop then delete alias file "Practices" of desktop
  make new alias file at desktop to (POSIX file "/Applications/Practices.app")
  set name of result to "Practices"
end tell' >/dev/null
echo "Installed: /Applications/Practices.app (+ Desktop alias), $BIN/practicesctl, $BIN/uv"
