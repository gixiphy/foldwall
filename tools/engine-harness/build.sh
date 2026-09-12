#!/bin/bash
# 把 Foldwall 的 DesktopVideoEngine 連同兩個播放核心編成一支獨立的命令列程式，
# 在桌面層真的播、真的換核心。給 P0／P1 驗收用（見 docs/mpv-integration-plan.md）。
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
repo="$source_dir/../.."
build_dir="${TMPDIR:-/tmp}/foldwall-engine-harness"
mkdir -p "$build_dir"

# 先把 FoldwallCore.framework 建好，然後問 xcodebuild 它在哪。
xcodebuild build -project "$repo/Foldwall.xcodeproj" -scheme Foldwall -destination 'platform=macOS' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -quiet
products="$(xcodebuild -project "$repo/Foldwall.xcodeproj" -scheme Foldwall -configuration Debug \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/ { print $3; exit }')"
[[ -d "$products/FoldwallCore.framework" ]] || { echo "找不到 FoldwallCore.framework：$products" >&2; exit 1; }

xcrun clang -c -fobjc-arc -fmodules -I "$repo/ThirdParty" -I "$repo/Foldwall/Playback" \
  -o "$build_dir/MPVBridge.o" "$repo/Foldwall/Playback/MPVBridge.m"
xcrun swiftc -swift-version 6 -F "$products" \
  -Xcc -I -Xcc "$repo/ThirdParty" -Xcc -I -Xcc "$repo/Foldwall/Playback" \
  -import-objc-header "$repo/Foldwall/Playback/Foldwall-Bridging-Header.h" \
  -framework AppKit -framework FoldwallCore -Xlinker -rpath -Xlinker "$products" \
  -o "$build_dir/engine-harness" \
  "$source_dir/main.swift" \
  "$repo/Foldwall/DesktopVideoEngine.swift" \
  "$repo/Foldwall/Playback/DesktopPlaybackSurface.swift" \
  "$repo/Foldwall/Playback/AVPlayerSurface.swift" \
  "$repo/Foldwall/Playback/MPVLibrary.swift" \
  "$repo/Foldwall/Playback/MPVSurface.swift" \
  "$repo/Foldwall/Log.swift" \
  "$build_dir/MPVBridge.o"
printf '%s\n' "$build_dir/engine-harness"
