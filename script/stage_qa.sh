#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ensure_qa_closed() {
  if /usr/bin/pgrep -x GuitargetQA >/dev/null 2>&1; then
    echo 'Guitarget QA 仍在运行。请先在应用菜单中正常退出（⌘Q），确认退出后重试。' >&2
    echo '本次已停止：不会覆盖运行中的程序，也不会把启动参数交给旧进程。' >&2
    exit 1
  fi
}
ensure_qa_closed
swift build
QA_BUNDLE="$PWD/artifacts/Guitarget QA.app"
# The app may have been opened while SwiftPM was building. Check again before copying.
ensure_qa_closed
mkdir -p "$QA_BUNDLE/Contents/MacOS" "$QA_BUNDLE/Contents/Resources"
cp "$(swift build --show-bin-path)/Guitarget" "$QA_BUNDLE/Contents/MacOS/GuitargetQA"
cp script/Info.plist "$QA_BUNDLE/Contents/Info.plist"
cp script/Guitarget.icns "$QA_BUNDLE/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable GuitargetQA' "$QA_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.guitarget.qa' "$QA_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Guitarget QA' "$QA_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Guitarget QA' "$QA_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDocumentTypes:0:LSHandlerRank Alternate' "$QA_BUNDLE/Contents/Info.plist"
bash script/finalize_app_bundle.sh "$QA_BUNDLE"
if [ "${1:-}" = "--system-isolation-smoke" ]; then
  bash script/stage_audio_test_source.sh
  open "$QA_BUNDLE" --args "--system-isolation-smoke=$PWD/artifacts/system-isolation-bundled" "--system-isolation-player=$PWD/artifacts/Audio Test Source.app/Contents/MacOS/AudioTestSource"
elif [ "${1:-}" = "--hardware-smoke" ]; then
  open "$QA_BUNDLE" --args --hardware-smoke "$PWD/artifacts"
else
  open "$QA_BUNDLE" --args --self-check "$PWD/artifacts/app-self-check.json"
fi
