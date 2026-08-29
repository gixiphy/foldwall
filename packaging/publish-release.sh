#!/bin/bash
#
# 把已經打包好的 DMG 發佈成 GitHub Release。
#
# 這支不建置也不簽名——DMG 由 packaging/make-dmg.sh 產出（含公證）。
# 這裡只做「對外那一步」：打 tag、推 tag、建 Release、傳 DMG。
#
# 用法：
#   ./packaging/publish-release.sh              # 發佈 project.yml 裡的版本
#   ./packaging/publish-release.sh 0.6.5        # 指定版本
#   ./packaging/publish-release.sh --dry-run    # 只檢查，不動遠端
#   ./packaging/publish-release.sh --yes        # 不問確認（沒有 TTY 時用）
#   ./packaging/publish-release.sh --notes-file notes.md
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION=""
NOTES_FILE=""
DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --notes-file) NOTES_FILE="$2"; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "✗ 不認識的選項：$1"; exit 1 ;;
    *) VERSION="$1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | tr -d ' "' | cut -d: -f2)"
TAG="v$VERSION"
DMG="$ROOT/dist/Foldwall-$VERSION-arm64.dmg"

echo "==> 發佈 $TAG"

# ---- 前置檢查。全部先跑完再動遠端：tag 推出去就收不回來了。----

command -v gh >/dev/null || { echo "✗ 沒有 gh CLI：brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || {
  echo "✗ gh 沒登入。先跑：gh auth login"
  exit 1
}

# 工作區必須乾淨。tag 指的是 commit，不是你硬碟上的檔案——留著未提交的改動
# 就代表 tag 上的原始碼和 DMG 裡的不是同一份。
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ 工作區有未提交的改動，tag 會指到和 DMG 不同的原始碼："
  git status --short | sed 's/^/    /'
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "⚠️  目前在 ${BRANCH}，不是 main"

git fetch --quiet origin
if [ -n "$(git rev-list "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
  echo "✗ 本地有還沒推的 commit，先 git push"
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "✗ tag $TAG 已經存在（本地或遠端）。要重發請先刪掉它。"
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "✗ Release $TAG 已經存在"
  exit 1
fi

[ -f "$DMG" ] || {
  echo "✗ 找不到 $DMG"
  echo "  先跑：NOTARY_PROFILE=<側寫名> ./packaging/make-dmg.sh"
  exit 1
}

# 公證票證一定要驗。沒公證的 DMG 傳上去，別人下載後 Gatekeeper 直接擋，
# 而 Release 一旦發出去，換檔案也救不回已經下載的人。
# 注意 stapler validate 失敗時 exit code 非 0，這裡刻意不讓 set -e 吃掉訊息。
if ! STAPLE="$(xcrun stapler validate "$DMG" 2>&1)"; then
  echo "✗ DMG 沒有公證票證，Gatekeeper 會擋："
  printf '%s\n' "$STAPLE" | sed 's/^/    /'
  echo "  重打包：NOTARY_PROFILE=<側寫名> ./packaging/make-dmg.sh"
  exit 1
fi
echo "    公證票證 ✓"

# DMG 裡的版本要和 tag 對得起來——dist/ 裡放著好幾版，很容易傳錯一個。
DMG_APP_VERSION="$(
  MOUNT="$(mktemp -d)"
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
  defaults read "$MOUNT/Foldwall.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rmdir "$MOUNT" 2>/dev/null || true
)"
[ "$DMG_APP_VERSION" = "$VERSION" ] || {
  echo "✗ DMG 裡的 app 是 ${DMG_APP_VERSION}，但要發的是 $VERSION"
  exit 1
}
echo "    DMG 版本 $DMG_APP_VERSION ✓"

# ---- 發佈說明。----
#
# 起點優先用上一個 tag；還沒有 tag 的話（第一次發佈）退回上一個 release: commit。
FROM="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -z "$FROM" ]; then
  FROM="$(git log --format='%H' --grep='^release:' --skip=1 -1 || true)"
fi

if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || { echo "✗ 找不到 $NOTES_FILE"; exit 1; }
  NOTES="$(cat "$NOTES_FILE")"
else
  RANGE="HEAD"
  [ -n "$FROM" ] && RANGE="$FROM..HEAD"
  # 版本號 bump 那筆對使用者沒有意義，濾掉。
  CHANGES="$(git log --no-merges --reverse --format='- %s' "$RANGE" | grep -v '^- release:' || true)"
  [ -n "$CHANGES" ] || CHANGES="- 無"
  NOTES="$(cat <<EOF
需要 macOS 26 以上、Apple Silicon。DMG 已經 Apple 公證，直接打開安裝即可。

## 這版改了什麼

$CHANGES
EOF
)"
fi

echo
echo "---- 發佈說明 ----"
printf '%s\n' "$NOTES"
echo "------------------"
echo "檔案：${DMG}（$(du -h "$DMG" | cut -f1)）"
echo

if [ "$DRY_RUN" = 1 ]; then
  echo "（--dry-run，到此為止，沒有動遠端）"
  exit 0
fi

if [ "$ASSUME_YES" = 1 ]; then
  echo "（--yes，略過確認）"
else
  read -r -p "確定發佈 ${TAG}？[y/N] " CONFIRM
  case "$CONFIRM" in
    y|Y) ;;
    *) echo "取消"; exit 1 ;;
  esac
fi

echo "==> 打 tag"
git tag -a "$TAG" -m "Foldwall $VERSION"
git push origin "$TAG"

echo "==> 建 Release 並上傳 DMG"
# tag 已經推上去了，這裡失敗的話 tag 會留著：訊息要講清楚怎麼收尾。
if ! printf '%s' "$NOTES" | gh release create "$TAG" "$DMG" \
  --title "Foldwall $VERSION" --notes-file -; then
  echo "✗ 建 Release 失敗，但 tag $TAG 已經推上遠端了。"
  echo "  重試前先刪：git tag -d $TAG && git push origin :refs/tags/$TAG"
  exit 1
fi

echo
echo "完成：$(gh release view "$TAG" --json url -q .url)"
