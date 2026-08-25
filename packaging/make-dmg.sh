#!/bin/bash
#
# 打包 Foldwall 成可安裝的 DMG。
#
# 簽名：優先用 Developer ID Application（可分發＋可公證）；沒有就退回
# Apple Development（只能在本機跑，Gatekeeper 會擋其他機器）。
# 公證需要 Developer ID 憑證與 notarytool 憑證側寫，見 README。
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | tr -d ' "' | cut -d: -f2)"
# 建置產物一律放 iCloud 外面：iCloud 同步磁碟上所有檔案，**不看 .gitignore**，
# 幾百 MB 的中間產物放在專案裡會讓它每次編譯都上傳一輪。
BUILD="${TMPDIR:-/tmp}/foldwall-build"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 選簽名身分
IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
  echo "⚠️  沒有 Developer ID Application 憑證，改用開發憑證：$IDENTITY"
  echo "    產物只能在本機跑，無法公證、無法給別台機器。"
fi
[ -n "$IDENTITY" ] || { echo "找不到任何簽名憑證"; exit 1; }

echo "==> 產生專案"
xcodegen generate >/dev/null

echo "==> Release 建置（$IDENTITY）"
echo "    建置目錄：$BUILD"
rm -rf "$BUILD"
xcodebuild -scheme Foldwall -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  build >/dev/null

APP="$BUILD/Build/Products/Release/Foldwall.app"
[ -d "$APP" ] || { echo "建置產物不存在"; exit 1; }

echo "==> 驗證簽名"
codesign --verify --deep --strict "$APP"
# 不要用 grep -q：提早關閉管道會讓 codesign 收到 SIGPIPE，pipefail 誤判成失敗
SIGN_INFO="$(codesign -dv "$APP" 2>&1 || true)"
if printf '%s' "$SIGN_INFO" | grep -q 'flags=0x10000(runtime)'; then
  echo "    Hardened Runtime ✓"
else
  echo "    ⚠️  Hardened Runtime 未生效（ad-hoc 簽名會這樣）"
fi
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Foldwall")"
[ "$ARCHS" = "arm64" ] || { echo "架構不是純 arm64：$ARCHS"; exit 1; }
echo "    arm64 only ✓"

echo "==> 組 DMG"
mkdir -p "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Foldwall-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "Foldwall $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

echo "==> 簽 DMG"
codesign --sign "$IDENTITY" "$DMG"

# 把建置產物從 LaunchServices 取消登錄。
# 否則 build-release 裡的 .appex 會被系統當成一個「已安裝」的桌布 extension，
# 和之後裝進 /Applications 的那份同 bundle id 打架（桌布清單出現重複／過期項目）。
"$(xcode-select -p)/../Frameworks/LaunchServices.framework/Support/lsregister" \
  -u "$APP" 2>/dev/null || \
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -u "$APP" 2>/dev/null || true

echo
echo "完成：$DMG"
echo "大小：$(du -h "$DMG" | cut -f1)"

# 公證：需要 Developer ID Application 憑證 + notarytool 憑證側寫。
# 側寫由你自己建立一次（會問 Apple ID 與 app-specific password）：
#   xcrun notarytool store-credentials foldwall \
#     --apple-id <你的 Apple ID> --team-id T87VR9424E --password <app-specific password>
# 然後：NOTARY_PROFILE=foldwall ./packaging/make-dmg.sh
if [ -n "${NOTARY_PROFILE:-}" ]; then
  case "$IDENTITY" in
    "Developer ID Application"*) ;;
    *) echo "✗ 公證需要 Developer ID Application 憑證，目前是：$IDENTITY"; exit 1 ;;
  esac

  echo "==> 公證中（會等 Apple 回覆，通常數分鐘）"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> 釘上票證"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "已公證，可以給任何 Mac 安裝。"
else
  echo
  echo "未公證。要公證：先取得 Developer ID Application 憑證，建立 notarytool 側寫後"
  echo "執行 NOTARY_PROFILE=<側寫名> ./packaging/make-dmg.sh"
fi
