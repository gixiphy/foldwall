# Foldwall 播放引擎驗收工具

把正式 app 裡的 `DesktopVideoEngine`（連同 AVPlayer 與 mpv 兩個核心、libmpv 橋接層）編成一支獨立程式，在指定螢幕的桌面層真的播。跟 `tools/playback-compare` 不同：那個是整合前的原型，這個跑的是**正式那份程式碼**，只是少了排片、來源與設定。

```bash
tools/engine-harness/build.sh
"${TMPDIR}/foldwall-engine-harness/engine-harness" <螢幕 UUID> /path/a.mp4 /path/b.mp4
```

需要 Homebrew 的 mpv（`brew install mpv`）；沒裝的話會看到引擎回退到 AVPlayer 與原因。螢幕 UUID 可以在「診斷播放不順」的報告裡看到。正在跑的 Foldwall 不必關，但那台螢幕若也被 Foldwall 標成播影片，兩邊會疊在一起。

40 秒的腳本：mpv 開始播 A、預載 B、播完自動接上 → 第 14 秒換到 AVPlayer（同一支從同一秒接著播）→ 第 22 秒換回 mpv → 暫停／恢復 → 切單片循環再切回 → 印出診斷報告、收掉。每秒印一行正在播的與實際核心；結束時 `activeCount` 要是 0。

看什麼：

- `firstFrame` 每支只該記一次；`switched：預載接上，無停頓` 是播完接上的路。
- 換核心那兩筆 `started：從 N 秒接著播`，N 要接近換之前的位置。
- 報告裡 mpv 的 `硬體解碼` 要是 `videotoolbox`，掉幀計數不該持續增加。

這是生命週期與換核心的檢查，**不能取代肉眼看流暢度**，也不是 20 分鐘連播的驗收——那要拿正式 app 配問題片跑。
