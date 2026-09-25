#!/bin/zsh
# Builds Practices.app with the Command Line Tools alone (swift build + swiftc), for when
# xcodebuild is unavailable. The real build is xcodegen + xcodebuild (run.sh).
set -e
cd "$(dirname "$0")/.."
(cd PracticesCore && swift build -q)
OBJ=PracticesCore/.build/arm64-apple-macosx/debug
APP=build/dev/Practices.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 6 -target arm64-apple-macosx15.0 -parse-as-library -Onone -g -DDEBUG \
  -I "$OBJ/Modules" PracticesApp/Sources/Practices/*.swift "$OBJ"/PracticesCore.build/*.o \
  -o "$APP/Contents/MacOS/Practices"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.practices.app</string>
  <key>CFBundleName</key><string>Practices</string>
  <key>CFBundleExecutable</key><string>Practices</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$APP" >/dev/null 2>&1
echo "$APP"
