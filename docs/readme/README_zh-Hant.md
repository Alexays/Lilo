<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md) · [한국어](README_ko.md) · **繁體中文**

# Lilo

**讓你的網路生活，綻放。**

為 Mac 減輕負擔，讓上網更快，預設保護隱私。免費且開放原始碼。

[![持續整合](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![授權：MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![狀態：公開測試版](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#安裝)

[網站](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[安裝](#安裝) ·
[從原始碼編譯](#從原始碼編譯) ·
[文件](../README.md) ·
[參與貢獻](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo 開啟「工作」空間：側邊欄顯示釘選網站、資料夾與分頁，旁邊是網頁及終端機分頁" width="900">
</picture>

</div>

Lilo 是為習慣使用側邊欄的人打造的 Mac 瀏覽器，並非另一個 Chromium 分支。
它以原生 Swift 與 AppKit 開發，採用 macOS 內建的 WebKit 引擎，同時仍能執行你仰賴的
Chrome 延伸功能。終端機分頁就在網頁旁邊，你已使用的 AI 代理程式也能透過內建 MCP
伺服器，在專屬空間中操作瀏覽器。免費、採用 MIT 授權、不需要帳號。如果你正準備離開
Arc，只要點按幾下，就能匯入空間、釘選分頁與資料夾。

> **狀態：公開測試版。** Lilo 已可供日常使用，但仍處於測試階段：部分功能可能尚未完善，
> 介面也持續調整中。歡迎[回報遇到的問題](https://github.com/Alexays/Lilo/issues)。
> [ROADMAP.md](../../ROADMAP.md) 列出優先事項與不在計畫內的目標。

加入 [Discord 社群](https://discord.gg/NyJRAapk76)，分享意見並取得 Lilo 使用協助。

## 為什麼選擇 Lilo

大多數 Arc 替代品，是加上新側邊欄的 Chromium。Lilo 保留側邊欄，重新打造其餘部分。

- **不使用 Chromium。** 不內附瀏覽器引擎，也不使用 Electron：採用 Swift、AppKit 與系統
  WebKit，側邊欄和設定則以 Svelte 製作。記憶體用量更低，電池續航足以應付一整天，
  並隨每次 macOS 更新取得 Apple 的安全性更新。
- **預設保護隱私。** 不需要帳號，沒有遙測、分析或伺服器：你的操作不會傳送給此專案。
  預設阻擋廣告與追蹤器，像 Safari 一樣防止跨網站追蹤，並啟用 Global Privacy Control
  （macOS 27）。Lilo 自行發出的每一項要求，都有[清單與關閉方式](../../PRIVACY.md#requests-lilo-makes-on-its-own)。
- **仍可使用 Chrome 延伸功能。** 離開 Chromium 通常也代表得放棄其延伸功能。在 Lilo 中，
  Chrome Web Store 延伸功能只需點按「加入 Lilo」，即可安裝至 WebKit 原生執行環境
  （[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **由你的代理程式操作，本身不含 AI。** 沒有額外塞入聊天機器人：你已在執行的代理程式
  （Claude Code、Codex、Cursor 或任何 MCP 用戶端）透過內建 MCP 伺服器使用真正的瀏覽器，
  在專屬空間與暫用個人檔案中工作，並在傳送、付款或刪除前先詢問你。
- **網頁旁的終端機。** 以 Ghostty 為基礎的終端機分頁，與網站一起放在側邊欄，
  顯示其儲存庫的分支與待處理變更。
- **由你作主。** 採用 MIT 授權。整個介面是在 WebKit 上運作的 Svelte 層，
  你可以修改，並在幾秒內重新編譯。

## 功能

**瀏覽**

- **空間與個人檔案**：每個空間都有表情符號與顏色，並使用各自的個人檔案登入；
  滑動即可切換。私密空間關閉後會忘記所有內容。
- **側邊欄**：釘選分頁、喜好項目、最多五層巢狀資料夾（可鎖定）、拖移排序，
  以及音訊與播放控制項。
- **指令列**（`Cmd+T`）：在同一欄位中搜尋分頁、歷史記錄、書籤、空間與所有動作，
  依你的使用習慣排序。
- **最近使用的分頁**（`Ctrl+Tab`）：依使用順序，切換各空間中最近使用的分頁。
- **預覽**：釘選分頁中通往其他網站的連結，或按住 `Shift` 點按的任何連結，
  都會在原網頁上方開啟。
- **小視窗**（`Cmd+Option+N`，可從任何 App 開啟）：以小視窗處理單一連結或搜尋，
  需要繼續時再送到空間中。
- **自行整理的分頁**：未釘選且不再使用的分頁，會在你為各空間設定的時間後封存；
  `Cmd+Shift+K` 可清除這些分頁，按一下快速鍵即可查看封存。
- **連結規則**：從其他 App 開啟的連結，會前往規則指定的空間或小視窗。
- **分割顯示**：最多四個分頁並排，重新啟動後會回復。
- **快速鍵**：所有快速鍵都能重新指定，可從 Lilo 或 Arc 的預設組開始。
- **匯入**：直接從 Mac 讀取 Safari、Firefox、Zen 和 Chromium 瀏覽器（Chrome、Arc、
  Brave、Edge、Vivaldi、Opera、Dia、Comet、Chromium）的書籤、已開啟分頁與空間、
  歷史記錄、Cookie 及延伸功能。

**延伸功能與網頁**

- **Chrome 延伸功能**：透過 WebKit 原生延伸功能執行環境支援 Manifest V3，並以小型
  Swift 處理程式補足 WebKit 缺少的 API（[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **密碼管理工具**：初始設定會提供你使用的工具（1Password、Bitwarden、Dashlane、
  KeePassXC、NordPass、Proton Pass）。
- **串流**：透過 FairPlay 播放受保護的影片與音樂；支援 YouTube 4K HDR。
- **內容阻擋**：持續更新 EasyList、EasyPrivacy 與 uBlock Origin 清單，
  支援外觀過濾與小型指令碼。
- **截圖**：擷取後會以卡片浮在網頁上方，可立即標示編輯、儲存或關閉。
- **還有更多**：閱讀器模式、子母畫面（通話會浮在永遠置頂的面板中）、網頁翻譯、
  Web Serial、AppleScript、「捷徑」動作與專注模式過濾條件。

**為開發者打造**

- **終端機分頁**：採用 libghostty-vt 與 Metal 算繪，在網頁旁開啟終端機
  （`Cmd+D` 在旁邊，`Cmd+Shift+D` 在下方），側邊欄會顯示分支與待處理變更。
- **變更檢視**：檢視儲存庫中的所有差異，包含影像。
- **工作時保持喚醒**：長時間執行的指令會讓 Mac 保持喚醒，即使闔上上蓋也是如此，
  完成後便允許睡眠。
- **透過 MCP 使用代理程式**：內建 MCP 伺服器，請參閱[供 AI 代理程式使用](#供-ai-代理程式使用)。

## 供 AI 代理程式使用

Lilo 內建 MCP 伺服器。開啟後，你已在執行的代理程式（Claude Code、Claude Desktop、
Codex、Cursor 或任何 MCP 用戶端）便能在你身旁操作真正的 WebKit 瀏覽器。
Lilo 本身不含 AI。

- **專屬空間。** 代理程式會在「代理程式」空間的資料夾中開啟分頁，使用暫用個人檔案，
  每次工作階段結束後即清除。不會佔用你的鍵盤、滑鼠或分頁，也絕不會看到私密空間。
  經你允許後，代理程式可以借用你的個人檔案。
- **先由你同意。** 代理程式傳送、付款、刪除或發佈前，Lilo 都會詢問（允許一次、
  一律允許此網站或拒絕），將你的檔案交給網頁前也會詢問。每個用戶端只需核准一次，
  授權會綁定實際執行的程式，而非它自稱的名稱。
- **點一下即可連接。** 在「設定」>「AI 代理程式」中，開啟「允許 AI 代理程式使用 Lilo」，
  再點按 Claude Code、Claude Desktop、Codex 或 Cursor 旁的「連接」：Lilo 會將自己加入
  該用戶端的 MCP 伺服器。其他用戶端可從「其他代理程式」拷貝設定。

接著可以像這樣要求代理程式：

```text
在 Lilo 中開啟 localhost:3000/checkout，使用測試卡付款，找出訂單失敗的原因。
檢查主控台與網路。
```

工具涵蓋：

- **分頁與導覽**：操作代理程式資料夾中的分頁，以及不共用 Cookie 或登入狀態的獨立分頁。
- **輸入**：點按、輸入文字、按鍵、捲動、拖移、填寫表單、上傳檔案與影像。
- **讀取網頁**：含元件參照的輔助使用樹狀結構、文字搜尋與網頁文字。
- **截圖**：擷取整個網頁或單一元件，並錄製 GIF。
- **主控台與網路**：訊息、含完整回應的要求、HAR 輸出與 Cookie。
- **網路模擬與環境模擬**：模擬、失敗或延遲的要求；使用者代理、配色、減少動態效果、
  列印媒體、額外標頭、初始化指令碼，以及檢視區大小。
- **效能**：載入與繪製指標、記憶體及時間軸分析。
- **網頁檢閱器**：WebKit 原生檢閱器通訊協定、指令與事件。
- **指令碼**：在網頁中執行 JavaScript、使用分頁的 Cookie 執行 `fetch`，
  並透過 `run` 或 `browser_batch` 在一次往返中串接多個呼叫。
- **個人檔案**：列出個人檔案、經你允許後借用，或重設暫用個人檔案。

[docs/AI-AGENTS.md](../AI-AGENTS.md) 說明詳細規則：何時會詢問、何時不會，以及哪些錯誤需要你處理。

## 安裝

你可以：

- 從[發行版本](https://github.com/Alexays/Lilo/releases/latest)下載 DMG，或
- 使用 Homebrew 安裝：

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo 透過已簽署的 Sparkle 更新自行更新。

### 系統需求

- macOS 26 或以上版本。Global Privacy Control 需要 macOS 27。

## 從原始碼編譯

先安裝 Xcode 27 與 Node.js 22.6+（[完整先決條件](../../CONTRIBUTING.md#requirements)）：

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # 檢查先決條件，並取得或編譯 App 所需內容
make install                    # 將 Release 版本安裝至 /Applications，取代已安裝的版本
open /Applications/Lilo.app
```

`make bootstrap` 會指出缺少的項目與安裝方法。若只修改介面，安裝 Node.js 即可：
`make ui-preview` 會在瀏覽器中開啟介面，並即時重新載入
（[CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)）。

不需要 Apple Developer 帳號。從原始碼編譯的版本預設使用 ad-hoc 簽署；
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing) 說明相關取捨，以及如何使用免費 Apple ID 簽署。

## 文件

- [docs/](../README.md)：架構、除錯、在地化、發行與 AI 代理程式
- [COMPATIBILITY.md](../../COMPATIBILITY.md)：延伸功能與網站相較於 Chrome 仍有哪些差異
- [PRIVACY.md](../../PRIVACY.md)：Lilo 自行發出的每一項要求
- [ROADMAP.md](../../ROADMAP.md)：已推出的功能、接下來的計畫，以及不在計畫內的目標

## 參與貢獻

歡迎提交 Pull Request。[CONTRIBUTING.md](../../CONTRIBUTING.md) 說明環境設定、開發流程
與 Pull Request 檢查清單。問題請到 [Discussions](https://github.com/Alexays/Lilo/discussions)
提出（[SUPPORT.md](../../SUPPORT.md)），安全性漏洞則請私下回報
（[SECURITY.md](../../SECURITY.md)）。所有參與者皆須遵守[行為準則](../../CODE_OF_CONDUCT.md)。

## 授權

採用 MIT 授權，請參閱 [LICENSE](../../LICENSE)。內附的第三方元件列於
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)。
