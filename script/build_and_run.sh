#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist/Guitarget.app"

# Ask the document application to close normally; a cancelled save keeps it running.
if pgrep -x Guitarget >/dev/null; then
  osascript -e 'tell application id "com.guitarget.mac" to quit' || exit 1
  for attempt in 1 2 3 4 5; do
    pgrep -x Guitarget >/dev/null || break
    sleep 1
  done
  if pgrep -x Guitarget >/dev/null; then
    echo "Guitarget 仍在运行。请处理保存对话框后重试。" >&2
    exit 1
  fi
fi
swift build
BUILD_BINARY="$(swift build --show-bin-path)/Guitarget"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/Guitarget"
cp "$ROOT_DIR/script/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$ROOT_DIR/script/Guitarget.icns" ]; then
  cp "$ROOT_DIR/script/Guitarget.icns" "$APP_BUNDLE/Contents/Resources/"
fi
codesign --force --deep --sign - "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open "$APP_BUNDLE" ;;
  --verify)
    /usr/bin/open "$APP_BUNDLE"
    sleep 2
    pgrep -x Guitarget
    ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/Guitarget" ;;
  --logs)
    /usr/bin/open "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "Guitarget"'
    ;;
  --telemetry)
    /usr/bin/open "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.guitarget.mac"'
    ;;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
