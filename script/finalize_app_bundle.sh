#!/usr/bin/env bash
set -euo pipefail
APP_BUNDLE="${1:?usage: finalize_app_bundle.sh /path/Application.app}"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_BUNDLE/Contents/Info.plist")"
case "$ICON_NAME" in
  *.icns) ;;
  *) ICON_NAME="$ICON_NAME.icns" ;;
esac
if [ ! -s "$APP_BUNDLE/Contents/Resources/$ICON_NAME" ]; then
  echo "应用图标缺失或为空：$APP_BUNDLE/Contents/Resources/$ICON_NAME" >&2
  exit 1
fi

codesign --force --deep --sign - "$APP_BUNDLE"
# Copying files inside an existing bundle leaves its directory date unchanged.
# Notify LaunchServices of this build so Finder and the Dock refresh its icon.
touch "$APP_BUNDLE/Contents" "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"
