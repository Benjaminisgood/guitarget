#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEST_SOURCE_BUNDLE="$PWD/artifacts/Audio Test Source.app"
mkdir -p "$TEST_SOURCE_BUNDLE/Contents/MacOS"
swiftc -O script/AudioTestSource.swift -o "$TEST_SOURCE_BUNDLE/Contents/MacOS/AudioTestSource"
cat > "$TEST_SOURCE_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.guitarget.audio-test-source</string>
  <key>CFBundleExecutable</key><string>AudioTestSource</string>
  <key>CFBundleName</key><string>Audio Test Source</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$TEST_SOURCE_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TEST_SOURCE_BUNDLE"
