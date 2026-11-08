#!/bin/zsh
# Builds dist/Practices-<ver>.dmg (the app, ad-hoc signed, not notarised), the only artifact:
# the app carries the CLI and MCP server in Contents/Helpers and copies it into ~/.practices/bin
# itself («Начало» / «Настройка»). ./install.sh is the from-source path.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

(cd PracticesApp && xcodegen generate >/dev/null)
xcodebuild -project PracticesApp/Practices.xcodeproj -scheme Practices -configuration Release \
  -derivedDataPath build/release build 2>&1 | grep -E "error:|\*\* BUILD" || true
APP=build/release/Build/Products/Release/Practices.app
[ -d "$APP" ] || { echo "Release build not found: $APP"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

codesign -s - --deep --force "$APP"

mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/dmg/Practices.app"
ln -s /Applications "$STAGE/dmg/Applications"
DMG=dist/Practices-$VER.dmg
hdiutil create -volname "Practices $VER" -srcfolder "$STAGE/dmg" -ov -format UDZO "$DMG" >/dev/null

echo "$PWD/$DMG"
shasum -a 256 "$DMG"
