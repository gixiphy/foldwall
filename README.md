# Foldwall

macOS 26+ 選單列 app：資料夾當來源，靜態做**隨機蒙太奇**桌布（每螢各自合成），影片走私有 Wallpaper 管線做桌面＋鎖屏。

規格權威：iCloud `Hermes/App/foldwall/foldwall-design.md`。

## 現況

v1 程式碼完成（Task 0–11），191 個單元測試綠。待人工驗收項目見 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

## 怎麼用

1. 啟動後圖示在選單列（不進 Dock）。
2. 三種來源可混用，加好就會進同一個蒙太奇池：
   - **資料夾**：選單 → 來源資料夾 → 加入資料夾…（本機、SMB、以及 Box／pCloud／
     Dropbox／OneDrive／Google Drive 等 File Provider 掛載點都算資料夾）
   - **照片相簿**：選單 → 設定 → 照片相簿（走 PhotoKit，首次會跳系統授權）
   - **網路影片**：設定 → 網路來源 → **Pexels 影片**（免 OAuth、直接給 mp4、授權允許；不做 YouTube，見下方風險表）
   - **網路來源**：選單 → 設定 → 網路來源（Unsplash／Pexels／Pixabay／Wallhaven／
     Flickr 公開搜尋／Immich／RSS。API key 存 Keychain）

   之後每 5 分鐘換一次構圖。
3. 影片要**兩步**：先在 系統設定 → 桌布 → **Foldwall** 選片，再回選單勾 **此螢幕改用影片**。
   只做第一步的話，下一輪靜態桌布會把影片蓋掉。
4. 雙螢時每台各自合成；勾了影片的那台不寫靜態。

## 架構

```
Foldwall.app（選單列，不沙盒）
├── FoldwallCore.framework   純邏輯，191 測試鎖死
│   ├── MediaIndexer         掃描分類、濾 sidecar（只看副檔名，不開檔）
│   ├── FolderIndex          索引快取：背景重掃，refresh 不等它
│   ├── ImageLoader          下採樣、EXIF 方向、壞檔 throw
│   ├── MontageComposer      隨機構圖（CoreGraphics，決定性）
│   ├── PostProcessor        灰階／棕褐／去飽和（Core Image）
│   ├── StillPipeline        每螢一張 → setDesktopImageURL
│   ├── Materializer         File Provider 物化、SMB 快取 LRU
│   ├── Scheduler            純狀態機（事件進、動作出）
│   ├── SourceRule           依電池／專注模式調整來源
│   ├── PowerPolicy          full / reduced / paused
│   └── BookmarkCodec/FolderStore
└── FoldwallExtension.appex  fork 自 Phosphene，播影片（沙盒）
```

靜態管線**完全不碰私有 API**：`WallpaperExtensionKit` 哪天斷了，蒙太奇輪播照常運作。

## 風險與限制（先讀）

| 項 | 說明 |
| --- | --- |
| **私有 API** | 影片管線 fork 自 [Phosphene](https://github.com/kageroumado/phosphene)（MIT），`dlopen` 私有 `WallpaperExtensionKit`。**macOS 大版本可能直接斷**。靜態蒙太奇不碰私有 API，是後備。 |
| **不沙盒** | v1 不進 App Sandbox、不進 Mac App Store。發布走 Developer ID 簽名＋公證 DMG。 |
| **僅 macOS 26+ / Apple Silicon** | 只編 `arm64`，不做 universal、不編 x86。 |
| **TCC 授權** | 非沙盒 app 靠 TCC：桌面／文件／下載、網路磁碟區、`~/Library/CloudStorage/*` 首次背景存取會跳系統授權框。重灌或改 bundle id 會重跳。嫌煩可自行給 Full Disk Access。 |
| **多 Space** | 靜態只寫每螢**當前 Space**；其他 Space 停留舊圖（全 Space 需私有 CGSSpace API，v1 刻意不碰）。 |
| **大型來源要等背景掃描** | 資料夾索引在背景跑，refresh 不等它——網路／相簿來源幾秒就能出第一張圖，資料夾的圖等掃完才進池（選單顯示「掃描中」）。實測 SMB 相簿 645,344 張圖約 2 分 50 秒掃完，掃完後自動補一輪合成。掃完前**不做影片差異同步**，否則會把還在來源裡的影片誤刪。 |
| **來源要先掛載** | 不實作雲端硬碟的 OAuth。這類來源必須是 Finder 已掛載的路徑。斷線＝標離線、換下一張，**不黑屏**。 |
| **網路來源有速率上限** | 免費 API 額度有限（例如 Unsplash 每小時 50 次）。Foldwall 以磁碟快取當池，池太薄或距上次逾 30 分才補貨，不會每 5 分鐘打一次 API。 |
| **照片要 entitlement** | Hardened Runtime 下（即使不沙盒）TCC 要求 `com.apple.security.personal-information.photos-library`，缺了連授權框都不會跳，app 也不會出現在系統設定的照片清單裡。已加入 `Foldwall.entitlements`。 |
| **專注模式非公開格式** | macOS 沒有公開 API 能查詢**目前是哪個**專注模式（`INFocusStatusCenter` 只給開／關，且要 entitlement）。Foldwall 讀 `~/Library/DoNotDisturb/DB/`——不是私有 API 呼叫，但格式沒保證。解析全部寬容處理：讀不到就當沒開，規則靜默失效，桌布不受影響。 |
| **不做 OAuth** | SmugMug 與 Flickr 私人相簿需要 OAuth，刻意不做。Flickr 只支援公開搜尋。 |
| **不做 YouTube** | 三條路全不通：Data API 是 Google API（規格第一條「放棄 Google」）；官方 IFrame 嵌入要求播放器可見、不被遮蔽、顯示廣告，桌布定義上就違反；抽 `googlevideo` 串流網址是規避技術保護措施。**串流不比下載寬鬆**。網路影片改走 Pexels Videos。 |
| **影片預設不拷** | 影片需拷進 extension container（沙盒 extension 讀不了 app 的 bookmark）。來源若是 NAS，那是幾十到幾百 GB——所以「設定 → 影片桌布 → 啟用影片桌布」**預設關閉**，開了才拷，而且是**輪替**不是囤積：一次只放 1–3 支（視大小，單輪上限 512MB；單檔超過 512MB 一律不收），下次換一批。**觸發點是螢幕重新亮起**（睡醒／螢保結束／解鎖）、最少間隔 30 分鐘，不跟桌布輪換同步。關掉開關會把 container 清空。 |
| **影片要兩步** | 系統設定選片 **＋** 選單勾「此螢幕改用影片」。漏勾第二步會被下一輪靜態桌布蓋掉。 |

鎖屏：macOS 14 起鎖屏預設顯示桌布，所以靜態蒙太奇會**免費出現在鎖屏**。

## 開發

原始碼與規格同住一個 iCloud 資料夾：`Hermes/App/foldwall/`（規格在上層，程式碼在 `src/`）。

> ⚠️ **建置產物不要放進這個資料夾。** iCloud 同步磁碟上的所有檔案，**不看 `.gitignore`**——
> 一次 Release 建置就是 228 MB，放在專案裡會讓 iCloud 每次編譯都上傳一輪。
> 用下面的指令或 `packaging/make-dmg.sh`，兩者都已把輸出導到 `$TMPDIR`。

需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。加了新檔案或改
`project.yml` 之後都要重新產生專案：

```bash
xcodegen generate
```

建置與測試（`FOLDWALL_DD` 把產物導出 iCloud）：

```bash
source .xcodebuild-env
xcodebuild -scheme Foldwall -destination 'platform=macOS' ${=FOLDWALL_DD} build
xcodebuild -scheme Foldwall -destination 'platform=macOS' ${=FOLDWALL_DD} test
```

> **zsh 要寫 `${=FOLDWALL_DD}`**（macOS 預設 shell）。zsh 不對未加引號的變數做字詞分割，
> 寫成 `$FOLDWALL_DD` 會把 `-derivedDataPath /path` 整串當成**一個**參數，
> xcodebuild 只會吐出 usage 然後結束。bash 下兩種寫法都可以。

用 Xcode 開的話，`Foldwall.xcodeproj` 直接開沒問題——Xcode 預設的 DerivedData
本來就在 `~/Library/Developer/Xcode/`，不在 iCloud 裡。

## 打包安裝檔

```bash
./packaging/make-dmg.sh
```

產物在 `dist/Foldwall-<版本>-arm64.dmg`。腳本會自動選簽名憑證、驗證 Hardened Runtime
與純 arm64，任一項不符就中止。

### 簽名憑證兩種，別搞混

| 憑證 | 用途 | 能不能公證 |
| --- | --- | --- |
| **Apple Development** | 本機開發測試 | **不行**。裝到別台 Mac 會被 Gatekeeper 擋 |
| **Developer ID Application** | 對外分發 | 可以。這才是 notarized DMG 需要的 |

取得 Developer ID Application（需付費 Apple Developer Program；Organization 帳號
只有 Account Holder 能建立）：Xcode → Settings → Accounts → 選 team →
Manage Certificates → 左下 **+** → **Developer ID Application**。

### 公證

憑證側寫只需建立一次（這步會問你的 Apple ID 與 app-specific password，自己執行）：

```bash
xcrun notarytool store-credentials foldwall --apple-id <你的 Apple ID> --team-id T87VR9424E
```

之後打包時帶上側寫名，腳本會自動送件、等待、釘票證：

```bash
NOTARY_PROFILE=foldwall ./packaging/make-dmg.sh
```

## 歸屬

影片 extension fork 自 Phosphene（MIT，作者 kageroumado），LICENSE 保留於 `ThirdParty/`。

## 授權

MIT，見 [LICENSE](LICENSE)。

影片桌布 extension（`FoldwallExtension/`）fork 自 [Phosphene](https://github.com/kageroumado/phosphene)（MIT），
授權原文保留在 [ThirdParty/Phosphene-LICENSE](ThirdParty/Phosphene-LICENSE)。
