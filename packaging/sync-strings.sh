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
# 跑完用 Xcode 打開 Localizable.xcstrings 補英文，或直接編 JSON。
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

echo "== 檢查英文 =="
python3 - <<'PYEOF'
import json, sys

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
        unit = entry.get('localizations', {}).get('en', {}).get('stringUnit', {})
        value, state = unit.get('value'), unit.get('state')
        if value is None:
            print(f'  沒有英文  {path}: {key!r}'); bad += 1
        elif state != 'translated':
            print(f'  狀態 {state}  {path}: {key!r}'); bad += 1
        elif cjk(value):
            print(f'  英文裡有中文  {path}: {key!r} -> {value!r}'); bad += 1

print('全部有英文' if not bad else f'{bad} 條要處理')
sys.exit(1 if bad else 0)
PYEOF
