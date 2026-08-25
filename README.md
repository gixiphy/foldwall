# Foldwall

macOS 26+ 選單列 app：資料夾當來源，靜態做**隨機蒙太奇**桌布（每螢各自合成），影片走私有 Wallpaper 管線做桌面＋鎖屏。

規格權威：iCloud `Hermes/App/foldwall/foldwall-design.md`。

## 現況

開發中。任務進度見 `docs/`。

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

## 歸屬

影片 extension fork 自 Phosphene（MIT，作者 kageroumado），LICENSE 保留於 `ThirdParty/`。
