#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen，请先安装：brew install xcodegen" >&2
  exit 1
fi

MODE="${1:-all}"

generate() {
  xcodegen generate
}

build_mac() {
  xcodebuild -project GuitargetDocs.xcodeproj -scheme GuitargetDocs \
    -configuration Debug -destination 'platform=macOS' build
}

build_ios() {
  xcodebuild -project GuitargetDocs.xcodeproj -scheme GuitargetDocsMobile \
    -configuration Debug -destination 'generic/platform=iOS Simulator' build
}

case "$MODE" in
  generate) generate ;;
  mac) generate && build_mac ;;
  ios) generate && build_ios ;;
  all) generate && build_mac && build_ios
    echo ""
    echo "BUILD SUCCEEDED：macOS 与 iOS Simulator 双平台构建通过。" ;;
  run) generate && build_mac
    APP_PATH="$(xcodebuild -project GuitargetDocs.xcodeproj -scheme GuitargetDocs -configuration Debug -destination 'platform=macOS' -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ { print $2; exit }')/GuitargetDocs.app"
    /usr/bin/open "$APP_PATH" ;;
  *) echo "usage: $0 [all|mac|ios|generate|run]" >&2; exit 2 ;;
esac
