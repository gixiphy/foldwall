#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${TMPDIR:-/tmp}/foldwall-playback-compare"
frameworks="${IINA_FRAMEWORKS:-/Applications/IINA.app/Contents/Frameworks}"
if [[ ! -f "$frameworks/libmpv.2.dylib" ]]; then
  echo '找不到 IINA 的 libmpv；請安裝 IINA，或設定 IINA_FRAMEWORKS。' >&2
  exit 1
fi
# 標頭用倉庫裡釘死的那份（ThirdParty/mpv，v0.40.0，ISC），不再從網路抓。
include_dir="$source_dir/../.."
[[ -s "$include_dir/ThirdParty/mpv/client.h" ]] || { echo '找不到 ThirdParty/mpv/client.h' >&2; exit 1; }
app="$build_dir/Foldwall Playback Compare.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -Wall -Wextra \
  -I "$include_dir/ThirdParty" "$source_dir/main.m" "$frameworks/libmpv.2.dylib" \
  -Wl,-rpath,"$frameworks" -framework Cocoa -framework AVFoundation -framework OpenGL \
  -o "$app/Contents/MacOS/FoldwallPlaybackCompare"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FoldwallPlaybackCompare</string>
<key>CFBundleIdentifier</key><string>app.foldwall.playback-compare</string>
<key>CFBundleName</key><string>Foldwall Playback Compare</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
