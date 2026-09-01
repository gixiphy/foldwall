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

# 選簽名身分。
#
# 開發憑證**釘死**這一張，不要用 `head -1` 撿：keychain 裡同名的
# 「Apple Development: HSUEN-YU WU」有兩張，分屬不同 Team——
#   S5LZ4TWLLL → 2ENEDJHX95（個人）    ← 用這張
#   D5647Z57T3 → T87VR9424E（Microlife）
# 而 `security find-identity` 的輸出順序沒有保證。撿錯的後果不是建置失敗，
# 是 TeamIdentifier 悄悄換人：裝上去之後 TCC 照片授權與資料夾書籤會全部重來。
DEV_IDENTITY="Apple Development: HSUEN-YU WU (S5LZ4TWLLL)"
EXPECTED_TEAM="2ENEDJHX95"

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -z "$IDENTITY" ]; then
  # 找不到就中止，不要靜默退到別張憑證
  security find-identity -v -p codesigning | grep -qF "$DEV_IDENTITY" || {
    echo "✗ 找不到指定的開發憑證：$DEV_IDENTITY"
    echo "  keychain 裡目前可用的身分："
    security find-identity -v -p codesigning | sed 's/^/    /'
    exit 1
  }
  IDENTITY="$DEV_IDENTITY"
  echo "⚠️  沒有 Developer ID Application 憑證，改用開發憑證：$IDENTITY"
  echo "    產物只能在本機跑，無法公證、無法給別台機器。"
fi

echo "==> 產生專案"
xcodegen generate >/dev/null

# 公證的兩個硬性要求，都是 `xcodebuild build`（非 archive）不會自己做對的：
# - 簽名要帶安全時間戳（--timestamp），少了會被退件「does not include a secure timestamp」
# - 不得注入 get-task-allow（那是掛除錯器用的），build 動作預設會注入、archive 才會關
# 開發憑證那條維持原樣：--timestamp 要連網，本機開發簽名沒必要多這個依賴。
SIGN_FLAGS=""
INJECT_BASE_ENTITLEMENTS="YES"
case "$IDENTITY" in
  "Developer ID Application"*)
    SIGN_FLAGS="--timestamp"
    INJECT_BASE_ENTITLEMENTS="NO"
    ;;
esac

echo "==> Release 建置（${IDENTITY}）"   # 一定要加大括號：zh_TW.UTF-8 下 bash 會把全形「）」吃進變數名
echo "    建置目錄：$BUILD"
rm -rf "$BUILD"
xcodebuild -scheme Foldwall -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$INJECT_BASE_ENTITLEMENTS" \
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

# TeamIdentifier 才是使用者感受得到的身分：它一變，TCC 授權與資料夾書籤就掉。
# 憑證選對了不代表簽出來的 team 就對，所以驗產物、不驗意圖。
TEAM="$(printf '%s\n' "$SIGN_INFO" | sed -n 's/^TeamIdentifier=//p')"
[ "$TEAM" = "$EXPECTED_TEAM" ] || {
  echo "✗ TeamIdentifier 是 $TEAM，預期 $EXPECTED_TEAM"
  echo "  換 team 會讓照片授權與資料夾書籤全部重來。"
  exit 1
}
echo "    Team $TEAM ✓"

# appex 的 entitlements 一定要驗產物。零 entitlement 的 appex 照樣建置成功、
# 照樣過 codesign --verify，但系統不會把它登錄成桌布 extension——「系統設定 →
# 桌布」就默默少一塊 Foldwall。0.6.1／0.6.2 就是這樣壞掉的：公證那條路關掉
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS，把 ENABLE_APP_SANDBOX 生成的 .xcent
# 一起關掉了。
APPEX="$APP/Contents/Extensions/FoldwallExtension.appex"
APPEX_ENTS="$(codesign -d --entitlements - "$APPEX" 2>/dev/null || true)"
case "$APPEX_ENTS" in
  *com.apple.security.app-sandbox*) ;;
  *)
    echo "✗ appex 沒有 app-sandbox entitlement，系統不會登錄成桌布 extension"
    echo "  實際簽到的 entitlements：${APPEX_ENTS:-（空）}"
    exit 1
    ;;
esac
case "$APPEX_ENTS" in
  *get-task-allow*)
    echo "✗ appex 帶著 get-task-allow，公證會被退件"
    exit 1
    ;;
esac
echo "    appex sandbox ✓"
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
# shellcheck disable=SC2086 — SIGN_FLAGS 是刻意的字組展開（空字串時展開成無）
codesign --sign "$IDENTITY" $SIGN_FLAGS "$DMG"

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
#     --apple-id <你的 Apple ID> --team-id 2ENEDJHX95 --password <app-specific password>
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

  # 票證釘上了不代表 Gatekeeper 會放行：stapler validate 只確認票證存在且能讀。
  # 這行才是使用者雙擊 DMG 時系統實際跑的那套評估，是離「別人的機器打不打得開」
  # 最近的一次檢查。
  echo "==> Gatekeeper 評估"
  spctl -a -t open --context context:primary-signature -vv "$DMG"

  echo "已公證，可以給任何 Mac 安裝。"
else
  echo
  echo "未公證。要公證：先取得 Developer ID Application 憑證，建立 notarytool 側寫後"
  echo "執行 NOTARY_PROFILE=<側寫名> ./packaging/make-dmg.sh"
fi
