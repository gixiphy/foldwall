# mpv 桌面播放整合與優化方案

狀態：進行中。2026-09-11 起草，2026-09-12 依程式碼與本機 IINA 實物驗證修訂；同日完成 P0 全部程式碼（量尺修正、`MPVRuntime`、dlopen 橋接、backend 抽出、渲染生命週期、單螢幕接線、設定頁與 README）、P1 的程式碼項目（即時改模式、單一暫停狀態機、活動宣告、錯誤分類、遮蔽暫停）與 P2 的量測、File Provider 來源身分、政策暫停統計；本機 `brew install mpv`（0.41.0）後用 `tools/engine-harness` 跑過生命週期、壓力、能耗矩陣與兩種載入失敗模擬。正式簽名的 app 抓到並修掉 LuaJIT 被 Hardened Runtime SIGKILL 的問題。**仍要人做**：問題片 20 分鐘肉眼流暢度、真的睡眠喚醒、雙螢插拔與改刷新率、公證與乾淨機器安裝。**結論**：mpv 可用但 CPU 約為 AVPlayer 的 5 倍，預設核心維持 AVPlayer；不自帶 libmpv。

目標是把使用者已確認流暢的 mpv 桌面播放路徑整合進 Foldwall，保留現有排片、螢幕配置與電源政策，並具備復原與長時間播放能力。

libmpv 的取得跟 yt-dlp 走同一條界線：**使用者自己用 Homebrew 裝，Foldwall 偵測、查版本、提示更新，不附帶、不下載、不替他跑 brew。** 沒裝就走 AVPlayer，設定頁講清楚怎麼裝。這條決定拿掉了自帶 LGPL 建置與 Frameworks 打包那整塊前置工作；若 Homebrew 路徑實測不足（見 P2），才回頭評估自帶。

## 已有證據與界線

- 同一支 H.264 29.970 fps 片源：使用者回報 IINA 順、QuickTime 與 Foldwall 的 AVPlayer 路徑持續微頓。
- 獨立原型在內建螢幕、桌面層、同片第 60 秒開始播放，使用者確認流暢。
- 合成影片與原片均完成 mpv → AVPlayer → mpv 的基本播放／切換測試。
- 原片短測 mpv 使用 VideoToolbox，回報解碼／輸出掉幀均為零；後續獨立播放曾回報一次輸出掉幀。這不是螢幕實際呈現量測，也不是長時間零掉幀證明。
- 時間戳比對發現診斷把空 CMSampleBuffer 當畫格，造成 VFR、缺少長度和 B-frame 誤報。排除後，19,999 格的間隔與 ffprobe 相同；尚未證明 AVPlayer 微頓的底層原因。
- 原型：`tools/playback-compare/`。它使用 IINA 的本機 libmpv、OpenGL、主執行緒渲染與同步控制呼叫，mpv 事件在 2 秒一次的 NSTimer 裡輪詢，尚無正式排片與完整資源管理。
- 原型實際連結的二進位（2026-09-12 查）：IINA 1.4.4 附帶的 libmpv v0.38.0（universal x86_64+arm64），FFmpeg 7.0.1 以 `--enable-gpl` 建置（libavcodec 標示 GPL v3+），mpv 啟用 gpl、vulkan、luajit、javascript、libarchive、libbluray；Frameworks 目錄共 73 個項目。原型下載的標頭是 v0.40.0，與動態庫差兩個版本。**使用者確認流暢的基準是這份 GPL 0.38 建置**，不是 Homebrew 那份。
- 本機 Homebrew（2026-09-12 查）：有 ffmpeg 8.0.1（libavcodec 62）、yt-dlp 2026.8.19、deno，**沒有 mpv**；formula 版本因網路不通未確認。Homebrew 的 dylib 以 `/opt/homebrew/opt/…`／`Cellar/…` 絕對路徑連結、ad-hoc 簽名：dlopen 不必處理 rpath，app 已關 library validation 所以載得進來。Homebrew mpv 連的 FFmpeg 大版本會跟原型的 7.0.1 不同，流暢度要在 Homebrew 那份上重新確認。
- **Hardened Runtime 與 LuaJIT（2026-09-12 實測）**：正式簽名的 app 啟動約 30 秒被 SIGKILL（Code Signature Invalid），死在 libmpv 的 `*/stats` script 執行緒——內建 stats script 起了 LuaJIT，要可執行記憶體，而 app 沒有 `allow-jit`。`load-scripts=no` 只擋使用者的 script。解法是把每個內建 script 的開關（osc、load-stats-overlay、load-console／load-osd-console、load-auto-profiles、load-select、load-positioning、load-commands、load-context-menu）都關掉，版本探測用的暫時 core 也一樣，桌布用不到它們；比放寬簽名好。Debug 建置與 `tools/engine-harness` 沒有 Hardened Runtime，看不到這個問題，**驗收一定要用正式簽名那份**。
- yt-dlp 現行機制（`VideoDownload.swift`、`PlaylistService.readToolVersion`、`YtDlpNotice`）：固定目錄找執行檔、本機跑一次 `--version`、一天問一次 GitHub `releases/latest`、兩邊都解得出版號才說落後、提示 `brew upgrade yt-dlp`、失敗輸出對成可直接給解法的分類（`DownloadFailureHint`）。libmpv 照這套做。

## 架構決策

保留 `VideoEngine.desktopWindow` 與 `systemExtension` 的設定語意。在桌面引擎內部增加可替換核心，避免新增頂層 case 導致既有設定、備份和 UI 的桌面專用判斷改義。具體依據：`SettingsSnapshot` 與 `SyncSnapshots` 對 `VideoEngine` 是嚴格 `decode`，新增 case 會讓新版寫出的備份與跨機同步快照在舊版整份解不開；coordinator 與設定 UI 十幾處 `needsDeployment` 判斷也都把「非 extension」等同桌面視窗。

```text
WallpaperCoordinator（現有來源、排片、冷卻與電源政策）
  └─ DesktopVideoEngine（每螢幕 session、視窗、回呼與備援）
       ├─ MPVPlaybackBackend
       │    ├─ 控制／事件佇列：load、pause、seek、EOF、error
       │    └─ 每螢幕渲染執行緒與 OpenGL context
       └─ AVPlayerPlaybackBackend
```

- 保留 `apply`、`setPaused`、`stopAll`、`playingURLs`、`reservedURLs`、`onVideoEnded`、`onPlaybackFailed`、`nextVideoProvider` 的上層責任。
- backend 負責載入、播放、定位、縮放、狀態與釋放；排下一支、跨螢幕避重複與來源冷卻仍由現有邏輯決定。
- 每個螢幕一個 mpv core 和 render context；不同刷新率各自同步，不能共用固定 60 Hz 計時器。
- 第一版保留原型已驗證的 OpenGL render API。Metal／Vulkan 作獨立後續評估，不把兩次渲染遷移綁在一起。
- 原型使用靜音但保留音訊路徑（`mute=yes`，沒有 `ao=null` 或 `aid=no`）。初次整合沿用此基準；關掉音訊解碼、改同步模式等須獨立 A/B，不能假設不影響播放節奏。
- 新增的桌面核心偏好照既有慣例用 `decodeIfPresent` 加預設值寫進 `SettingsSnapshot` 與 `SyncSnapshots`；舊備份缺這個鍵不是損壞。
- libmpv 用 dlopen 在執行期載入，不在連結期綁定：app 沒有 mpv 也要能啟動。C 橋接層以 dlsym 取符號，Swift 端只看到一個「載入成功／失敗原因」的結果型別。
- **一個行程只 dlopen 一次，握著 handle 到行程結束。** `brew upgrade mpv` 會換掉磁碟上的檔，已映射的舊庫照樣能用，但之後再 dlopen 會拿到新版，兩台螢幕各跑一版是在賭。新版一律下次啟動才生效，版本檢查發現「磁碟上的 ≠ 載入中的」就提示重新啟動。
- 診斷加核心資訊時沿用 `PlaybackEvent.engine` 字串（例如 `desktopWindow/mpv`），不改欄位。該型別定義在 `VideoSourceProfile.swift`，同時編進沙盒 appex，extension 寫出的 JSON 由主 app 解碼，加必填欄位會讓舊 extension 的紀錄解不開。

## P0：正式可用的垂直整合

交付一個可以安裝、選用 mpv、持續播放及回退的 Foldwall 本機建置。

1. **先修好量尺**（原列 P2，提前：這三項是 P0／P1 驗收要用的數字，用壞掉的尺去驗前兩階段沒有意義）
   - `VideoAnalyzer.timingAnalysis` 對每個 `copyNextSampleBuffer` 結果直接記一格，沒查 `CMSampleBufferGetNumSamples`，也沒處理多樣本 buffer。把 buffer 轉 `SampleTiming` 抽成純函式（輸入樣本數、PTS、duration），加真空 buffer 與多樣本 buffer 的測試，不必依賴影片 fixture；真實畫格缺少 duration 不可被靜默忽略。
   - `DesktopVideoEngine.setPaused(false)` 不看狀態有沒有變就重設 `startedAt`／`waitingSince`，而 `applyDesktopVideo` 每輪都呼叫它：「已播 N 秒」每次 refresh 歸零，進行中的停頓被抹掉起點。
   - 接上預載時只重建 aspect 與 ready 觀察者，`stateObserver` 仍抓舊 session 號，之後 `noteTimeControl` 一律被 guard 擋掉，第一次預載接上後停頓就再也記不到。
2. **libmpv 的偵測、載入、版本檢查與更新提示**（與 yt-dlp 同一套，純邏輯放 `FoldwallCore/MPVRuntime.swift`，仿 `VideoDownload.swift` 寫法與測試）
   - **找**：`libmpv.2.dylib` 只認 `/opt/homebrew/lib`、`/usr/local/lib` 兩個目錄，跟 `VideoDownloadTool.searchPaths` 同一個原則。IINA 內附的那份**不是**支援來源：它是別人 app 的內部檔、版本 0.38、IINA 一更新就可能變；只留給原型用。
   - **裝的是哪版**：兩個來源都記。設定頁還沒播之前跑一次 `/opt/homebrew/bin/mpv --version`（Homebrew 的 mpv formula 連 CLI 一起裝），解 `mpv v?X.Y.Z`；真的載入後從第一個 core 讀 `mpv-version` 與 `mpv_client_api_version()`，那才是「行程裡實際跑的」。兩者不一致就是磁碟上已換新版，提示重新啟動。
   - **上游是哪版**：問 `https://formulae.brew.sh/api/formula/mpv.json` 的 `versions.stable`，不問 GitHub。理由：更新指令是 `brew upgrade mpv`，拿 GitHub tag 比會在 bottle 還沒出來的那幾天叫使用者升一個升不上去的版本；yt-dlp 沒這個問題是因為它的 formula 幾小時內就跟上。一天問一次，兩邊都解得出版號才說落後，任何一邊查不到就不提。
   - **版本下限**：`mpv_client_api_version()` 主版號必須是釘死標頭的那個（v0.40.0 為 2），release 低於 0.38 不載，理由寫進提示：原型只在 0.38 以上驗過。太新不擋，只記錄。
   - **更新**：跟 yt-dlp 一樣，Foldwall 不跑 brew。設定頁的 `MpvNotice` 仿 `YtDlpNotice` 三態：「已偵測到 libmpv X.Y.Z」、「有新版 X.Y.Z：`brew upgrade mpv`」、「需要 libmpv：`brew install mpv`」，外加第四態「已更新，重新啟動 Foldwall 後生效」。
   - **載入失敗分類**（仿 `DownloadFailureHint`，每一種對一個解法）：找不到檔 → `brew install mpv`；dlopen 回 `Library not loaded`／`image not found` → 相依被 `brew upgrade ffmpeg` 之類換掉、mpv 還沒重建 → `brew reinstall mpv`；API 主版號不符或低於下限 → `brew upgrade mpv`；`mpv_create`／`mpv_initialize`／render context 建立失敗 → 不是使用者能修的，記 log、走備援。這幾類全部**不進來源冷卻名單**。
   - **分發的只有標頭**：釘死 v0.40.0 的 `client.h`、`render.h`、`render_gl.h` 三個 ISC 授權標頭連同授權聲明進 `ThirdParty/mpv/`，不再由 build script 下載。二進位一個都不附帶。
   - **完成條件**：沒裝 mpv 的機器啟動成功、走 AVPlayer、設定頁顯示安裝提示；`brew install mpv` 後不必重裝 app，重新啟動就用上；README 加「流暢播放與 mpv」一段，寫法對齊「片單網址與 yt-dlp」。
3. **抽出播放核心介面**（已做：`Foldwall/Playback/`）
   - 將現有 AVPlayer 實作放入 backend，先保持行為；新增小型 C／Objective-C libmpv 橋接層，避免 C pointer／callback 散落在 Swift UI。**做法**：`DesktopPlaybackSurface` 是每台螢幕一個的播放器介面（載入、預載、接上、播放、縮放、狀態、釋放），引擎保留視窗、session、排片預約、看門狗與事件紀錄；事件的「過期」由 surface 自己用世代號過濾。`MPVBridge.m` 用 dlsym 取整組符號，Swift 只看到 `MPVLibraryHandle`／`MPVCore`／`MPVRenderer`／`MPVOpenGLView` 四個物件。
   - 載入 mpv、建立 renderer 或解碼器失敗時，提供一次 AVPlayer 備援；失敗原因走第 2 項的分類，本機缺庫不能把影片當成壞片放入冷卻名單。（已做：`DesktopVideoEngine.resolveCore`／`makeSurface`，回退一次就記住到使用者再動核心設定。）
   - 分開記錄「使用者選的核心」與「實際核心／回退原因」。不因一次掉幀自動反覆切換。（已做：`DesktopPlaybackCoreStatus`，設定頁與診斷報告都讀它。）
4. **正式渲染生命週期**（已做，見 `MPVBridge.h` 開頭的執行緒規則）
   - 主執行緒只管理 NSWindow／NSView；控制命令與事件用序列佇列，mpv_render_* 放在專屬渲染執行緒。**做法**：每個 core 一條 control queue 撈事件、每個 renderer 一條 user-interactive 序列佇列做 `mpv_render_context_update`／`render`／`report_swap`，GL context 只在那條執行緒 current；開了 `MPV_RENDER_PARAM_ADVANCED_CONTROL`。view 是自帶 NSOpenGLContext 的 NSView（不是 NSOpenGLView），框變了在 CGL 鎖底下 update、可繪尺寸用原子變數交給渲染執行緒。
   - callback 只喚醒工作；合併重複喚醒，不讓待處理 frame 無上限堆積。
   - context 建立、current、resize 和釋放按同一套執行緒規則處理；渲染不可等待正在呼叫一般 libmpv API 的控制佇列。
   - teardown：失效 session、停止新工作與 callback、清完在途渲染、釋放 render context，再銷毀 mpv core。保護延遲 callback，避免 use-after-free。
   - **遮蔽的代價在這裡就要量。** macOS 會在桌布視窗被完全遮住時讓 AVPlayer 停下（見 `DesktopVideoEngine.swift` 開頭註解），mpv 加 OpenGL 沒有這個免費的省電，全螢幕視窗蓋著時照樣解碼加渲染。P0 先量出被遮蔽時兩個核心的 CPU／GPU 差距並記錄；要不要實作遮蔽暫停留給 P2 決定，但 P2 的能耗比較必須包含這個場景。（部分：引擎已把視窗遮蔽／露出記成 `policyChanged` 事件，量測還沒做。）
5. **單螢幕正式接線**（已做；多螢幕沿用同一套每螢幕一個 surface，但沒實測 60＋165 Hz 並播）
   - 接上現有桌面圖層、點擊穿透、所有縮放模式、手動換片與單片循環。（縮放：fill／fit 對到 `panscan`；單片循環：`loop-file=inf`，而且 mpv 換片不必像 AVPlayerLooper 那樣拆掉重建。）
   - 適用設定的 refresh 必須冪等：同一 URL／政策不再呼叫 play、seek 或重設 session 計時。
   - 核心切換只作用於影片視窗，盡可能維持來源與時間點；不重跑蒙太奇。（已做：`apply(core:)` 換核心時記下每台的 URL 與秒數，新 surface 從那一秒接著播；AVPlayer 那邊要等 item readyToPlay 再 seek，不然起點會被吞掉。）

驗收工具：`tools/engine-harness`（正式引擎、兩個核心、40 秒腳本）；肉眼流暢度與 20 分鐘連播仍要拿正式 app 配問題片跑。

2026-09-12 用 `tools/engine-harness` 模擬過的兩種失敗：把 `libmpv.2.dylib` 暫時改名 → 回退 AVPlayer，原因「沒有找到 libmpv（brew install mpv）」；把 `/opt/homebrew/opt/ffmpeg` 暫時改名 → 原因「libmpv 的相依找不到：…libavcodec.63.dylib（brew reinstall mpv）」；兩種都沒有把影片送進冷卻名單，改回來之後 mpv 又載得起來。

驗收：問題片與短片在正式 app 連播 20 分鐘，流暢度不退於原型（在 Homebrew 那份 libmpv 上重新確認，不是 IINA 那份）；設定視窗操作不中斷播放；反覆切核心 20 次無卡死／孤兒視窗。AVPlayer 備援可用，已選備援不被自動改回。沒裝 mpv 的機器：啟動、AVPlayer 播放、安裝提示三者都對；裝上後重啟即用；`brew upgrade mpv` 後正在播的不受影響、設定頁出現重啟提示；把 `/opt/homebrew/opt/ffmpeg` 暫時改名模擬相依斷裂，提示要指向 `brew reinstall mpv` 而不是把影片冷卻。

## P1：補齊現有功能與可靠性

在這階段通過前，不將 mpv 對所有既有使用者預設開啟。

- 接上單片循環、全部循環、隨機、手動下一片與 nextVideoProvider。session generation 配合 mpv 的檔案／playlist-entry 身分，遲到 EOF／error 不得推進新片。（已做：`MPVSurface` 用 playlist entry id 對「播完的是哪一支」，AVPlayer 那邊用觀察者世代號；`tools/engine-harness --stress` 跑 50 次手動下一片沒有錯推。）
- 播放模式改變不必沿用現行的 `stopAll` 整批重建：那是 AVPlayerLooper 在建 player 當下決定的限制，mpv 的 `loop-file` 是可即時改的屬性。AVPlayer backend 保留舊行為。（已做：`DesktopPlaybackSurface.setLoop`，mpv 即時改並丟掉預載；AVPlayer 回 false 走整批重建。）
- 下一支預備數有界：沿用每螢幕一個候選的排片預約，先預備檔案／讀取資料。不要直接假設 mpv playlist 等同 AVQueuePlayer 已預解碼。（已做：mpv 端 `prefetch-playlist=yes` 只開 demuxer；換目標前先 `playlist-clear`，playlist 永遠最多兩筆。）
- 實測片間接縫；若單一 core 無法滿足，再評估短時間雙播放器預解碼，設定全域並行解碼與記憶體上限，避免每螢永久養兩個 decoder。（已量：本機檔播完接預載，mpv 的第一格在 0.03～0.09 秒內出畫，AVPlayer 0.00～0.11 秒；單一 core 夠用，不做雙播放器。）
- 保留跨螢幕片源避重複與快取檔案保護；預載取消、跳片、拔螢幕都要解除舊預約。（已做：`reservedURLs` 含預載；換片走 `load` 會把 playlist 整份換掉，`teardown` 移除整台。）
- 今天 `screenDidSleep`／`screenDidWake` 直接呼叫 `setPaused`，排片時又依 tier 再呼叫一次，不是同一狀態機。改成睡眠、鎖定、專注規則、電源政策都走同一條；只有政策改變才切播放狀態。（已做：`WallpaperCoordinator.syncVideoPause` 是唯一決定的地方，睡眠／鎖定／螢保只改 `screensAsleep` 旗標。順手修掉一個 bug：螢幕睡著那一輪的 refresh 以前會把剛暫停的影片又放回去播。）
- 主 app 目前沒有任何活動宣告，只有原型有（`NSActivityUserInitiatedAllowingIdleSystemSleep`）。若正式版引入，須允許正常系統睡眠；暫停與全部停止時釋放。這是新東西，不是既有行為的延續。（已做：只有 mpv 在跑時宣告，`userInitiatedAllowingIdleSystemSleep`，暫停、遮住、停掉就收回；AVPlayer 自己會宣告。）
- 沿用現有喚醒輪替政策；引擎只執行上層計畫，不另起一套自動從頭播放規則。
- 支援解析度／縮放倍率／螢幕插拔／Spaces 變更。60 Hz 內建與 165 Hz 外接同時播放時不得互相牽動呈現時鐘。（架構上每螢幕一個 core 與渲染執行緒，各自跟自己的 vsync；`MPVOpenGLView` 在框與 backing scale 改變時於 CGL 鎖底下 update。**雙螢並播沒有實測。**）
- 對讀取失敗、格式失敗、解碼失敗分開處理；有界重建與備援都失敗後，才回報既有來源冷卻／下一片流程。（已做：`MPVRuntime.classifyPlaybackError` 把 mpv 錯誤碼分成讀取／格式／沒有軌／輸出；輸出建不起來不怪影片、直接改用 AVPlayer 接著播，其餘走既有的就地重建一次再冷卻。）
- 設定先提供「流暢播放（mpv）」與「相容播放（AVPlayer）」的明確選擇。舊設定仍可讀；升級初期保留既有選擇，達成驗收再決定預設切換。系統 extension 保持原行為。（已做；預設仍是 AVPlayer，而且看下面 P2 的能耗數字，**預設不該切**。）

驗收：50 次下一片／循環、20 次核心切換、10 次睡眠喚醒、雙螢插拔及更改刷新率。無重複前進、政策暫停誤報、黑畫面卡死或播放資源逐次累積。網路來源失敗可恢復或有界換片。

2026-09-12 `tools/engine-harness --stress`（內建螢幕、兩支本機測試片）：50 次手動下一片、20 次換核心、10 次暫停恢復、6 次改模式，結束時 activeCount 0、沒有殘留視窗；RSS 109 → 110（下一片）→ 123（換核心）→ 124 MB，沒有逐次階梯。真的睡眠喚醒、雙螢插拔與改刷新率**沒有自動化**，要人做。

## P2：省資源、診斷與發布收斂

- 以正式整合後的穩定版本作基準量 CPU、GPU、記憶體與 Energy Impact；固定片段／尺寸／螢幕，先暖機，再做至少 3 次等長比較。每次只改一個影響播放的選項。

  **2026-09-12 量測**（`tools/engine-harness --measure`，內建 60 Hz 螢幕 1440×900@2x、本機 1080p 29.97 fps H.264 10 Mbps 帶音軌的測試片、單片循環、暖機 10 秒後量 60 秒、各 3 次；CPU 是這個行程的 user+system 佔一顆核心的百分比；GPU 用 ioreg 的 Device Utilization %，是整台的、其他 app 也算進去，雜訊太大不列）：

  | 核心 | 狀態 | CPU % | RSS MB |
  | --- | --- | --- | --- |
  | AVPlayer | 可見 | 2.6／2.8／3.0 | 50～56 |
  | mpv | 可見 | 13.2／14.9／15.7 | 106～144 |
  | mpv | 可見，`aid=no` | 13.1／14.7／15.5 | 128～140 |
  | mpv | 被完全遮住、已暫停 | 0.2 | 81 |

  **mpv 的 CPU 是 AVPlayer 的 5 倍左右。** 硬體解碼與 interop 都是 videotoolbox（零拷貝），關掉音訊解碼沒差，所以成本在 render 路徑本身：每個 vsync 一次 `mpv_render_context_render` 走 OpenGL（Apple Silicon 上 OpenGL 是疊在 Metal 上的），加上 mpv core 自己的執行緒。這是 mpv 換來流暢度的代價，**預設核心維持 AVPlayer**；要降就是 Metal render path，那是計畫裡另列的評估，不在這一輪。
- 確認硬體解碼實際啟用；軟體回退需要看得到。降低畫質、丟格或改播放速度不能作為隱藏的省電捷徑。（已做：診斷報告列 `hwdec-current` 與 `hwdec-interop`，`MPVSurface` 觀察 hwdec-current，掉回非 VideoToolbox 會記 log。）
- 評估停用音訊解碼、背景活動宣告範圍、解碼預讀與真正完全遮蔽時暫停。遮蔽暫停以 P0 量到的差距決定值不值得做；做的話須驗證 Finder、Spaces 與桌面層判斷可靠，否則先維持既有政策。（結論：音訊解碼關了沒差，維持原型基準；活動宣告只給 mpv、允許系統睡眠；**遮蔽暫停做了**——被完全遮住的 mpv 從 15% 掉到 0.2%，值得。判斷用 `NSWindow.occlusionState`，跟系統替 AVPlayer 停下用的是同一個訊號；通知偶爾不來，看門狗每 10 秒對一次實際狀態補上。用自己開的不透明視窗蓋住當測試，四次只有一次收到通知，加了看門狗對帳之後 30 秒內一定抓到（0.2% CPU）。順帶驗到另一種真實情況：螢幕睡著、session 鎖住時 occlusionState 也是「不可見」，mpv 跟著停在 0.3%，露出來會由同一條路恢復。真的全螢幕 app 蓋住的情況沒有自動化驗證。）
- 將來源 buffer、媒體樣本、呈現間隔、播放 session 與政策暫停時間分開表達（空 buffer 計數、計時重設、stateObserver 三個修正已提前到 P0）。（已做：`PlaybackEventLog.pausedSummary` 把政策暫停跟停頓分開算，報告各列一行。）
- 常態診斷只保留有界事件、累計掉幀、核心／解碼器及近期摘要；需要時才取詳細呈現計時。不得把 render 呼叫數或播放器 time-pos 當成實際螢幕出畫數。
- 回報 File Provider 來源身分與目前物化狀態（查不到標未知）。現行 `VideoBufferPolicy.location` 的判準是 `volumeIsLocal`，Box／iCloud 的 File Provider 項目在本機 APFS 卷上，會被標成本機磁碟；`VideoAnalyzer.profile` 的 `isLocal` 同一個問題。`Materializer` 已有 `ubiquitousItemDownloadingStatus` 判斷可沿用。（已做：`VideoSourceLocation` 多了 `cloudMaterialized`／`cloudDataless`，用 `isUbiquitousItem` 或 `~/Library/CloudStorage` 路徑判斷，狀態查不到當成還沒下載；預讀與 `profile.isLocal` 跟著走。）
- 內部驗收後測 signed app、DMG、公證與乾淨安裝，乾淨安裝分「沒有 Homebrew mpv」與「有」兩種各跑一次。發布說明要說明適用的是桌面播放核心、mpv 要自己裝，不能暗示 extension 已改用 mpv。
- **要不要自帶 libmpv，在這裡才決定。** 判準：Homebrew 路徑在 P0／P1 實測中是否出現無法接受的狀況，例如 formula 長期落後、相依斷裂頻繁、或 Homebrew 建置的流暢度不及原型。真要自帶才進入 LGPL 相容建置、Frameworks、rpath、逐個簽署與 `otool -L` 路徑掃描那整套工作；現階段不做。（決定：**不自帶。** Homebrew 的 0.41.0 載得起來、VideoToolbox 零拷貝、formula 比 GitHub tag 只慢幾天；唯一踩到的坑是 Hardened Runtime 對 LuaJIT 的 SIGKILL，關掉內建 script 就解了，自帶也躲不掉那個。）

## 驗收片源與量測判準

| 類別 | 最小集合 | 判準 |
| --- | --- | --- |
| 已知問題 | 目前 H.264 29.97 fps 原片 | 同螢幕／片段／縮放，主觀不退於已確認流暢的原型 |
| 時間軸 | 24、29.97、60 fps，真 VFR／B-frame，非零起點 | 無錯速、遞增漂移；正常重複顯示格不算解碼掉幀 |
| 畫面 | H.264、HEVC、4K、直拍旋轉，另測 HDR | 比例、旋轉正確；HDR／色彩獨立確認 |
| 來源 | 本機、Box 已物化／待讀取、SMB、現有直接串流 | 讀取等待與播放器錯誤可區分，有界恢復 |
| 多螢 | 60 Hz + 165 Hz，改尺寸與縮放 | 各螢同步獨立，設定操作不造成持續抖動 |
| 長時間 | 20 分鐘流暢度 + 2 小時穩定性 | 掉幀不持續異常累積，記憶體無逐輪階梯成長，停播後資源回到穩定基線 |

內部掉幀指標配合肉眼對照判讀；不訂「所有格式在所有刷新率下一律零掉幀」這種無法代表觀感的門檻。換片延遲與睡眠恢復另列數據，不混入穩態播放。

## 實作落點

| 位置 | 改動 |
| --- | --- |
| `Foldwall/DesktopVideoEngine.swift` | 管理 facade、session、視窗及可替換 backend |
| 新增 `Foldwall/Playback/` | backend 介面（`DesktopPlaybackSurface`）、AVPlayer／mpv 實作、C／ObjC 橋接（`MPVBridge`）與 render lifecycle、`MPVLibrary`（一個行程只載一次） |
| `Foldwall/WallpaperCoordinator.swift` | 維持排片責任；只補必要的 backend 設定／狀態接線 |
| 新增 `FoldwallCore/MPVRuntime.swift` | 純邏輯：搜尋路徑、`--version` 與 `mpv-version` 解析、落後判斷、版本下限、載入失敗分類；仿 `VideoDownload.swift` |
| `Foldwall/SettingsView.swift`、`README.md` | `MpvNotice` 仿 `YtDlpNotice` 四態；「版本」分頁講為什麼 mpv 是外部工具；README 加「流暢播放與 mpv」 |
| `FoldwallCore/VideoEngine.swift`、設定／備份／字串表 | 桌面核心偏好、相容預設、三語說明 |
| `FoldwallCore/VideoAnalyzer.swift`、`Foldwall/VideoDiagnostics.swift` | 修正診斷誤報；報告加載入中的 libmpv 版本、`hwdec-current`、磁碟上的版本 |
| `ThirdParty/mpv/` | 釘死 v0.40.0 的三個 ISC 授權標頭與授權聲明；不放二進位 |
| `FoldwallCoreTests/`、`tools/engine-harness/` | 搜尋路徑／版號／落後／失敗分類／選項表單元測試（仿 `VideoDownloadTests`）；用正式引擎跑兩個核心的生命週期與換核心腳本 |

## 參考依據

mpv 的 [render API 契約](https://github.com/mpv-player/mpv/blob/v0.40.0/include/mpv/render.h)要求渲染與一般控制 API 避免互相等待，並規定 render context 必須先於 core 釋放。原型通過短測不表示這些正式生命週期工作可以略過。

mpv 的 [Copyright](https://github.com/mpv-player/mpv/blob/v0.40.0/Copyright)說明預設 GPL 與 LGPL 建置選項，也明示依賴（例如 FFmpeg 的建置模式）會影響結果。Homebrew 的 mpv 與 FFmpeg 都是 GPL 建置；Foldwall（MIT）不附帶、不下載它們，只在使用者自行安裝時 dlopen，跟呼叫使用者自己裝的 yt-dlp 是同一條界線，所以 LGPL 打包工作不在這個計畫裡。真要自帶（見 P2）那一天，這段才變成前置工作，而且不能把原型能連到 IINA 的 dylib 當成完成打包。
