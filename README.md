# Foldwall

macOS 26+ 選單列 app：資料夾當來源，靜態做**隨機蒙太奇**桌布（每螢各自合成），影片走私有 Wallpaper 管線做桌面＋鎖屏。

規格權威：iCloud `Hermes/App/foldwall/foldwall-design.md`。

## 現況

v1 程式碼完成（Task 0–11），56 個單元測試綠。待人工驗收項目見 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

## 怎麼用

1. 啟動後圖示在選單列（不進 Dock）。
2. **來源資料夾 → 加入資料夾…** 選一個有照片的資料夾。之後每 5 分鐘換一次構圖。
3. 影片要**兩步**：先在 系統設定 → 桌布 → **Foldwall** 選片，再回選單勾 **此螢幕改用影片**。
   只做第一步的話，下一輪靜態桌布會把影片蓋掉。
4. 雙螢時每台各自合成；勾了影片的那台不寫靜態。

## 架構

```
Foldwall.app（選單列，不沙盒）
├── FoldwallCore.framework   純邏輯，56 測試鎖死
│   ├── MediaIndexer         掃描分類、濾 sidecar 與過小圖
│   ├── ImageLoader          下採樣、EXIF 方向、壞檔 throw
│   ├── MontageComposer      隨機構圖（CoreGraphics，決定性）
│   ├── PostProcessor        灰階／棕褐／去飽和（Core Image）
│   ├── StillPipeline        每螢一張 → setDesktopImageURL
│   ├── Materializer         File Provider 物化、SMB 快取 LRU
│   ├── Scheduler            純狀態機（事件進、動作出）
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
| **來源要先掛載** | 不實作 Box／pCloud OAuth。來源必須是 Finder 已掛載的路徑。斷線＝標離線、換下一張，**不黑屏**。 |
| **影片佔磁碟** | 影片需拷進 extension container（沙盒 extension 讀不了 app 的 bookmark），磁碟用量會翻倍。 |
| **影片要兩步** | 系統設定選片 **＋** 選單勾「此螢幕改用影片」。漏勾第二步會被下一輪靜態桌布蓋掉。 |

鎖屏：macOS 14 起鎖屏預設顯示桌布，所以靜態蒙太奇會**免費出現在鎖屏**。

## 開發

需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。改 `project.yml` 後：

```
xcodegen generate
xcodebuild -scheme Foldwall -destination 'platform=macOS' build
xcodebuild -scheme Foldwall -destination 'platform=macOS' test
```

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
