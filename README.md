# OpenTalkType

原生 macOS AI 語音輸入。按住 fn 說話，放開就把整理好的文字插到游標位置。
開源、不上傳、無帳號，是 [Typeless](https://typeless.io) 的自由軟體版本。

錄音與語音辨識全程在這台 Mac 上完成；只有辨識後的逐字稿會送到你自己設定的 LLM
供應商（也可以指向本機模型，那就完全不出機器）。

## 三種模式

| 模式 | 觸發鍵 | 做什麼 |
|---|---|---|
| 聽寫 | 按住 `fn` | 把口語整理成通順文字，插入游標位置 |
| 翻譯 | 按住 `fn` + 左 `⇧` | 用中文說，輸出道地的目標語言（預設英文） |
| 問問題 | 按住 `fn` + `space` | 對**選取的文字**下指令，結果覆蓋選取範圍；沒有選取時直接回答並插入 |

三種都是按住說話、放開送出。觸發鍵可以在「設定 › 一般」改綁。

## 建置

需要 macOS 26.0 以上與 Xcode 26。零第三方相依，不用 SPM。

```sh
brew install xcodegen        # 只有第一次需要
xcodegen generate
open OpenTalkType.xcodeproj  # 或 xcodebuild -scheme OpenTalkType build
```

簽章用 ad-hoc（`CODE_SIGN_IDENTITY = "-"`），不需要 Apple 開發者帳號。

## 自我測試

GUI 沒辦法用讀原始碼驗證，所以 App 自己就是測試工具：

```sh
OpenTalkType.app/Contents/MacOS/OpenTalkType --selftest
```

只跑純邏輯檢查，不開視窗、不要權限、不連網，每項印一行 `PASS` / `FAIL`，
全過才 exit 0。

## 需要的兩個權限

- **麥克風** — 錄音。
- **輔助使用（Accessibility）** — 監聽 fn 鍵、讀取選取文字、貼上結果。
  沒有這個權限，事件攔截會直接失敗，快捷鍵完全沒反應。

兩個都可以在「設定 › 權限」看到即時狀態並重新要求。

## fn / 地球鍵設定

macOS 預設把 fn（地球鍵）綁在表情符號或聽寫上，不改的話按住 fn 會同時跳出
表情符號選單。請到：

- 系統設定 › 鍵盤 › **按下地球鍵時** → 改成「不執行任何動作」
- 系統設定 › 鍵盤 › 聽寫 → 把快捷鍵設成「關閉」

本 App 刻意**不攔截** fn 事件本身：WindowServer 的修飾鍵狀態在事件攔截點的上游更新，
吞掉 flagsChanged 會讓整個系統卡在 fn 按住的狀態。

## ad-hoc 簽章的 TCC 陷阱

本機重新建置會產生新的簽章身分，macOS 會**默默作廢**已授予的權限，
但系統設定裡的勾選看起來還是打勾的。症狀是「貼上突然沒反應了」。

解法：到「設定 › 權限」按**重新要求權限**，或在系統設定的輔助使用清單裡
把 OpenTalkType 移除後重新加入。

## 授權

MIT，見 [LICENSE](LICENSE)。
