# Foldwall v1 驗收

規格權威：iCloud `Hermes/App/foldwall/foldwall-design.md`
驗收機：MacBook Pro (M5)、macOS 26.6.2、Xcode 26.6 / Swift 6.3.3、arm64

## 自動化（CC 已勾）

| # | 項目 | 結果 |
| --- | --- | --- |
| 8 | `xcodebuild -scheme Foldwall -destination 'platform=macOS' test` | **綠**，56 測試（1 個視覺樣張預設跳過） |
| — | 只編 arm64、無 x86／universal | `lipo -archs` 全部只有 `arm64` |
| — | 不沙盒（app） | entitlements 無 `com.apple.security.app-sandbox` |
| — | 選單列 app，啟動不跳空視窗 | `LSUIElement = true`，無 `WindowGroup` |
| — | 無任何 Google API／帳號 | 原始碼零 `google`／`oauth` 字樣 |
| — | extension 被系統登錄 | `pluginkit -m -p com.apple.wallpaper` 列出 `app.foldwall.extension` |

單元測試覆蓋的規格行為：索引與 sidecar 過濾、短邊 <256px 濾除、書籤往返與改名、移除來源持久化、離線計數、蒙太奇尺寸／決定性／片數 clamp、後製四效果、EXIF 方向、壞檔 throw、每螢不同構圖、影片螢幕零次寫入、空池零次寫入、只留兩代檔案、電源分級表、排程器全部語意（暫停／單發／resume 立即／睡醒 catch-up／熱插拔不重設）、SMB 快取 LRU 淘汰。

## 待人工（需要真實資料夾、雙螢、鎖屏）

執行檔：`~/workspace/foldwall/DerivedData/Build/Products/Debug/Foldwall.app`（已在跑）

| # | 項目 | 步驟 |
| --- | --- | --- |
| 1 | 蒙太奇不是單張／四格 | 選單 → 來源資料夾 → 加入資料夾…（挑一個有照片的）。等一輪或按「下一張」，確認每次構圖不同 |
| 2 | 後製可套、random 會換 | 選單 → 後製，逐一切換灰階／棕褐／去飽和；選「隨機」後連按幾次「下一張」 |
| 3 | 雙螢構圖不同 | 接上 49" 超寬屏，確認兩台圖不一樣；確認選單裡**沒有**「全螢相同／只套一台」開關 |
| 4 | 影片桌面＋鎖屏 | 來源資料夾內放 mp4／mov → 系統設定 → 桌布 → **Foldwall** 選片 → 回選單勾「此螢幕改用影片」。鎖屏（Ctrl+Cmd+Q）確認也在動 |
| 5 | Box／pCloud dataless | 加入 `~/Library/CloudStorage/Box-Box/...`，確認未下載的檔案會先物化再合成 |
| 6 | SMB 斷線不黑屏 | 加入 `/Volumes/...`，拔掉網路，確認桌布保留、選單顯示「來源離線」 |
| 7 | 無 Google | 已由自動檢查涵蓋 |
| — | TCC 拒絕 | 對某來源拒絕授權 → 選單顯示離線／無權限、桌布不黑 → 系統設定核准 → 恢復 |
| — | 間隔 | 切 5 分鐘看兩輪自動輪換；切「每天」後闔蓋再開，確認**不會**提前換 |
| — | 移除來源 | 移除資料夾後池數立即變小，且該來源影片從 extension container 消失 |
| — | 空狀態 | 移除所有來源後選單顯示「尚未加入資料夾」，且啟動時**不彈** panel |

## 已知限制（設計內，非 bug）

- 靜態只寫每螢**當前 Space**，其他 Space 停留舊圖。
- 影片需**兩步**：系統設定選片＋選單勾「此螢幕改用影片」。漏勾會被下一輪靜態蓋掉。
- 影片拷進 extension container，磁碟用量翻倍。
- 私有 `WallpaperExtensionKit` 可能隨 macOS 大版本失效；靜態蒙太奇不受影響。

## 診斷

```bash
log stream --predicate 'subsystem == "app.foldwall"' --level info
```

extension 端日誌：`~/Library/Containers/app.foldwall.extension/Data/Documents/extension.log`
（`touch` 同目錄的 `VERBOSE_LOG` 可開詳細模式）
