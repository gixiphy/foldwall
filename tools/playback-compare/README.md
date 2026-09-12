# Foldwall 播放比較原型

在同一個螢幕、相同尺寸與片段起點，比較 libmpv 與現行 AVPlayer 路徑。這是獨立的本機驗證程式，尚未整合進 Foldwall 設定或片單排程。

## 建置與啟動

需安裝 Xcode 與 IINA。直接連結本機 IINA 的 `libmpv.2.dylib`；不修改 IINA、不複製或散布它的函式庫。`IINA_FRAMEWORKS` 可覆寫函式庫目錄。標頭用倉庫裡釘死的 `ThirdParty/mpv/`（mpv v0.40.0，ISC 授權），不從網路抓。

```bash
tools/playback-compare/build.sh
open -n "${TMPDIR}/foldwall-playback-compare/Foldwall Playback Compare.app" --args \
  /absolute/path/video.mp4 --start 60 --isolate
```

- `--start N`：兩個核心每次從 N 秒開始（預設 0）。
- `--screen UUID`：指定螢幕；預設讀 Foldwall 的影片螢幕設定，找不到則用主螢幕。
- `--isolate`：暫時結束正在執行的 Foldwall，避免重複解碼。正常結束比較程式時重新開啟原 app，不修改其設定。若比較程式被強制結束，需自行重開 Foldwall。

選單列的「比較：mpv／AV」可以切核心、一般視窗／桌面層、填滿／符合、螢幕、片源和起點。切核心會重播同一片段。畫面點擊穿透；透過選單結束比較。

原型讀取 Foldwall 的圖層與填滿／符合設定。其他縮放模式暫時視為填滿，可在選單調整。僅接受本機檔案路徑（包含已掛載的來源）。正常睡眠時停止播放，螢幕喚醒後從比較起點恢復。兩個核心都宣告同樣的背景活動並允許系統閒置睡眠。

## 驗證與紀錄

```bash
"${TMPDIR}/foldwall-playback-compare/Foldwall Playback Compare.app/Contents/MacOS/FoldwallPlaybackCompare" \
  /absolute/path/video.mp4 --start 3 --self-test
```

24 秒測試會依次啟動 mpv → AVPlayer → mpv，要求 mpv 有多次 render 呼叫與前進中的時間軸，且 AVPlayer 已 readyForDisplay 並前進，否則以非零狀態結束。這是生命週期與播放基本功能測試，不能取代肉眼檢查流暢度。

每兩秒寫入進度；mpv 額外記錄硬體解碼方式、decoder-frame-drop-count、frame-drop-count、render 呼叫次數。這些是播放器／原型內部計數，不能證明螢幕實際呈現每格的時間。AVPlayer 的 readyForDisplay 只表示可出畫，不能解讀為沒有掉幀。

mpv 使用公開 OpenGL render API、垂直同步與 auto-safe 硬體解碼，關閉使用者 mpv config/scripts，兩個核心均靜音。這不是 IINA 完整渲染與設定的複製；原型若仍不順，不能據此認定 IINA 的結果不成立。AVPlayer 測試的是持續播放，播畢重新啟動；不驗收無縫循環或多影片切換。

OpenGL 在 macOS 已棄用，這裡僅作快速 A/B 驗證；正式整合仍需處理渲染生命週期、多螢幕、排片與函式庫封裝。
