# mpv client API 標頭

來源：<https://github.com/mpv-player/mpv/tree/v0.40.0/include/mpv>，釘死 **v0.40.0**
（`MPV_CLIENT_API_VERSION` = `MPV_MAKE_VERSION(2, 5)`）。

| 檔案 | SHA-256 |
| --- | --- |
| `client.h` | `3c073236a09cb456c6e80587d5523c8771c32fb22ca014e0f99cc3d43905b75c` |
| `render.h` | `192691941602052f00df0587f126246c48785a1cf21de68d22a92ea1908d1c55` |
| `render_gl.h` | `48662c0ed9872a14dd9e1684105c97f69f94a0414709c254c5d372adc41d2e69` |

## 授權

這三個標頭是 **ISC** 授權（每個檔案開頭都有原文）：mpv 把 client API 的標頭刻意用比核心
寬鬆的授權釋出，好讓外部 wrapper 能用。**只有標頭在這裡。** libmpv 的二進位與它的相依
（FFmpeg 等）預設是 GPLv2+，Foldwall 不附帶、不下載，只在使用者自己用 Homebrew 裝了
之後 dlopen 它——跟呼叫使用者自己裝的 yt-dlp 是同一條界線。

## 為什麼釘版本

`mpv_client_api_version()` 回的是**執行期載入的那份**的版本，跟這裡的標頭不一定相同
（原型當初就是 v0.40.0 的標頭配 IINA 的 v0.38.0 動態庫）。主版號不同就是 ABI 不相容，
`MPVRuntime.checkAPIVersion` 會擋下來；升級這裡的標頭時要一起改
`MPVRuntime.headerClientAPIVersion` 與上面的校驗碼。
