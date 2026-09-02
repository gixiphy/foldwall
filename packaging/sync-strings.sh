#!/bin/bash
#
# 把程式碼裡的字串同步進 String Catalog，然後檢查有沒有漏翻。
#
# Xcode 的 IDE 會在每次建置後自動把新字串灌進 .xcstrings；**命令列的 xcodebuild
# 不會**——它只把字串抽成 .stringsdata 丟在 DerivedData 裡就結束。所以在終端機
# 改完 UI 字串之後要跑一次這支，否則新加的字串不會出現在 catalog 裡，
# 英文版就會靜默退回中文（key 是中文，查不到就原樣回傳）。
#
#   ./packaging/sync-strings.sh
#
# 跑完用 Xcode 打開 Localizable.xcstrings 補英文與簡體，或直接編 JSON。
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/foldwall-build"

echo "== 建置（抽字串）=="
xcodebuild -scheme Foldwall -destination 'platform=macOS' \
    -derivedDataPath "$BUILD" build > /dev/null

OBJ="$BUILD/Build/Intermediates.noindex/Foldwall.build/Debug"
for target in Foldwall FoldwallCore; do
    dir="$OBJ/$target.build/Objects-normal/arm64"
    echo "== sync $target/Localizable.xcstrings =="
    xcrun xcstringstool sync "$target/Localizable.xcstrings" --stringsdata "$dir"/*.stringsdata
done

echo "== 檢查英文與簡體 =="
python3 - <<'PYEOF'
import json, sys

# 只在繁體用的字。抓的是「簡體那欄直接複製繁體過來」——查不到 key 就回傳 key，
# 而 key 是繁體，所以漏翻的症狀是簡體介面裡冒出一句繁體，編譯與執行都不會抱怨。
# 這份清單跟 SchedulerTests.traditionalOnly 是同一份，改一邊要改另一邊。
TRADITIONAL = set(
    "個們來時後說讀點為與體麼樣機對從應當現發過進還連邊選錯錄長間際隨難電靜頁"
    "項預頭題類顯驗資夾檔螢網設統開關數圖備傳價兩區單圓實寫專尋層帳幾庫張強"
    "換擇斷書會東條業標權沒測滿無狀畫碼種稱筆紙組結給線縮總續舊蓋處號術補裝裡"
    "製見規視覽訊許詢試話該認誤請證護變讓負責費貼質軌載輪輸適遠釋鈕鋪鍵鎖鐘鑰"
    "閉階離雲響順須顆額飽齊齡")

def cjk(text):
    return any(0x4E00 <= ord(c) <= 0x9FFF for c in text)

bad = 0
for path in ('Foldwall/Localizable.xcstrings', 'FoldwallCore/Localizable.xcstrings'):
    catalog = json.load(open(path, encoding='utf-8'))
    for key, entry in sorted(catalog['strings'].items()):
        if entry.get('shouldTranslate') is False:
            continue
        if entry.get('extractionState') == 'stale':
            # 程式碼裡已經沒有這條了（改字或刪碼）。留著只會讓下一個人以為它還在用。
            print(f'  已無人使用  {path}: {key!r}'); bad += 1
            continue
        localizations = entry.get('localizations', {})

        unit = localizations.get('en', {}).get('stringUnit', {})
        value, state = unit.get('value'), unit.get('state')
        if value is None:
            print(f'  沒有英文  {path}: {key!r}'); bad += 1
        elif state != 'translated':
            print(f'  英文狀態 {state}  {path}: {key!r}'); bad += 1
        elif cjk(value):
            print(f'  英文裡有中文  {path}: {key!r} -> {value!r}'); bad += 1

        unit = localizations.get('zh-Hans', {}).get('stringUnit', {})
        value, state = unit.get('value'), unit.get('state')
        if value is None:
            print(f'  沒有簡體  {path}: {key!r}'); bad += 1
        elif state != 'translated':
            print(f'  簡體狀態 {state}  {path}: {key!r}'); bad += 1
        else:
            leftovers = ''.join(sorted(set(value) & TRADITIONAL))
            if leftovers:
                print(f'  簡體裡有繁體字（{leftovers}）  {path}: {key!r}'); bad += 1

print('英文與簡體都齊了' if not bad else f'{bad} 條要處理')
sys.exit(1 if bad else 0)
PYEOF
