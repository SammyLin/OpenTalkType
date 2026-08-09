[English](README.md) · 正體中文 · [日本語](README.ja.md) · [한국어](README.ko.md)

# OpenTalkType

按住 `fn` 講話，放開，整理好的文字就出現在你原本打字的地方。

[![CI](https://github.com/SammyLin/OpenTalkType/actions/workflows/ci.yml/badge.svg)](https://github.com/SammyLin/OpenTalkType/actions/workflows/ci.yml)

語音辨識全程在這台 Mac 上跑，聲音不會離開機器。真正送出去的只有辨識出來的文字，交給你自己設定的語言模型，
回來的是有標點、沒有贅字、可以直接用的句子，而不是辨識引擎的原始輸出。沒有帳號、沒有我們的伺服器、沒有任何回傳統計。

它同時也是唯一一個可以被別的軟體呼叫的 macOS 開源聽寫工具：URL scheme、App Intents、MCP server 三種都有。
這一段放在最前面，因為這才是選它的理由。

<!-- 螢幕截圖放這裡，需要兩張：
     1. 講話中的瀏海 HUD：黑色面板從螢幕缺口長出來，看得到即時逐字稿和音量條，底下是真的在用的 app。
     2. 主視窗的 Home 分頁：三張模式卡片和上面的按鍵標示。
     檔案放進 Design/，在這裡引用，然後把這段註解刪掉。 -->

---

## 自動化

聽寫本來就該是別的程式可以呼叫的一個功能。`fn` 走的那條流程，OpenTalkType 另外開了三道門給外面用。

### MCP server

`OpenTalkType --mcp` 是走 stdio 的無介面 MCP server，不開任何連接埠，跑的就是 app 本身那份程式碼，
所以模型拿到的是你真正的模式、真正的字典、真正的紀錄。

先到 **設定 › Automation** 打開，再把這段貼進 MCP 客戶端的設定檔：

```json
{
  "mcpServers": {
    "opentalktype": {
      "command": "/Applications/OpenTalkType.app/Contents/MacOS/OpenTalkType",
      "args": ["--mcp"]
    }
  }
}
```

設定 › Automation 裡會直接顯示你這份 app 的實際路徑，旁邊有複製按鈕。提供四個工具：

| 工具 | 用途 |
|---|---|
| `opentalktype_clean_text` | 用任一模式跑一次整理流程，輸入什麼文字都可以 |
| `opentalktype_history_search` | 搜尋聽寫紀錄，新的在前 |
| `opentalktype_add_term` | 新增字典詞條，連同它常被聽錯的寫法 |
| `opentalktype_list_modes` | 列出你定義過的模式和它們的 id |

預設是關的，而且是刻意的：只要本機有程式能執行這個檔案，它就能把你的整份聽寫紀錄讀走。

### URL scheme

同樣預設關閉，因為任何一個網頁都能開一條這種連結。

```
opentalktype://start?mode=dictate         用指定模式開始聽寫
opentalktype://stop                       結束這次、整理、貼上
opentalktype://cancel                     取消這次：不貼、不留
opentalktype://run?mode=dictate&text=…    跳過麥克風，直接整理這段文字
opentalktype://paste-last                 把上一次的結果再貼一次
```

Raycast、Keyboard Maestro、Stream Deck，或者 shell 裡一行 `open` 都夠用了。沒寫 `mode` 就是 dictate；
指定了一個不存在的模式則是什麼都不做，而不是默默用錯的模式聽寫。`run` 的文字上限兩萬字。

### App Intents

Start Dictation、Stop Dictation、Cancel Dictation、Clean Up Text、Add Dictionary Term 會出現在
捷徑、Spotlight，以及任何讀得到 intent 的地方。Clean Up Text 會把整理完的字串回傳，所以可以接在捷徑的後面繼續用。
模式那一欄是選單，內容就是你自己有的模式。這裡沒有開關：intent 只會因為你把它放進捷徑、而且你按下去了才跑。

### Shell action

每個模式都可以掛一行 `/bin/sh` 指令，文字整理好之後執行，環境變數有 `$OT_TRANSCRIPT`、`$OT_MODE`、
`$OT_APP`、`$OT_RAW`，同一份文字也會從 stdin 進去。指令有輸出的話，輸出就變成要貼上的文字。
一個欄位就能把一個模式變成 webhook、變成往筆記後面追加、變成呼叫任何一個 API。
沒有任何預設指令，你不打字它就不做事。

---

## 三種模式

內建三種，按著講、放開送出。

| 模式 | 按鍵 | 做什麼 |
|---|---|---|
| Dictate | 按住 `fn` | 把你說的整理成文字，插在游標處 |
| Translate | 按住 `fn` + 左 `⇧` | 用一種語言講，得到另一種語言的道地寫法 |
| Ask | 按住 `fn` + `space` | 對選取的文字下口頭指令，結果直接蓋掉選取範圍 |

連按兩下 `fn` 可以鎖定麥克風、空出雙手，再按一下結束。`Esc` 直接放棄這一次：不辨識、不貼上、不留紀錄。

模式是一筆一筆的資料，不是寫死的清單。到設定 › Modes 新增你自己的，名稱、圖示、系統提示、搭配鍵、shell 指令都自己決定，
內建那三個也能改，包括提示詞。其他地方全部跟著同一張表走：快捷鍵、上面那三道自動化的門、MCP 的模式清單、每個 app 的規則。

---

## 什麼東西會離開這台 Mac

錄音和辨識走 macOS 26 的 `SpeechAnalyzer`，用的是 Apple 的裝置端語音模型。聲音不會上傳，
語言模型下載完之後辨識完全不需要網路。

會離開的、而且是唯一會離開的，是辨識完的那段文字，送到你選的供應商去整理。

| 供應商 | 說明 |
|---|---|
| DeepSeek（預設） | 實測約一秒，中文品質好，而且很便宜 |
| Claude Code（本機 CLI） | **完全不用 API key**，直接沿用你已經登入的 Claude Code 訂閱。約五秒，因為每次都要冷啟動 CLI |
| Anthropic、OpenAI、Gemini | 用你自己的 API key，存在 macOS 鑰匙圈 |
| Local | 這台 Mac 上任何相容 OpenAI 介面的服務，例如 Ollama、LM Studio。什麼都不會離開這台機器 |

除此之外只剩更新檢查，它只問更新來源有沒有新版本。這項預設關閉，而且不是從「應用程式」資料夾執行的版本完全不會檢查。

---

## 字典

辨識引擎一定會把名字聽錯。字典就是拿來讓同事的名字、產品名、內部系統、指令不要再錯下去的地方，
也是中英夾雜能用的關鍵：你講一句中文裡面夾三個英文術語，那三個術語會照你自己的寫法出現。

一筆詞條就是「正確的寫法」加上「它常被聽成什麼」。這些詞會用在三個地方：在模型看到文字之前先做字面替換、
以權威清單的形式塞進系統提示、以及在選用 DictationTranscriber 引擎時當作辨識的詞彙提示。
替換一律是字面比對，不是 `\b` 那種字界正規表示式——中文字之間根本沒有 word boundary，那樣寫等於整個功能失效。

字典會自己長，兩條路都在文字貼出去之後才跑，所以不會拖慢任何一次聽寫：

- **配對。** 整理後多出來、但你其實沒那樣講的字，就是一次修正。它會連同被它取代掉的那串亂碼一起存起來，
  下次同樣的亂碼在模型介入之前就先被改對。
- **問模型。** 把整理好的文字丟回去問「裡面有哪些專有名詞和技術術語」。這半邊才是真正有用的：
  模型每次都默默寫錯的字根本不會被修正，只靠比對永遠學不到。

自動加進來的詞條會標示出來，可以像其他詞條一樣編輯或刪掉；辨識本來就拼對的詞不會加，清單才不會長得亂七八糟。
不想要的話到設定 › General 關掉。

---

## 其他

- **紀錄**存在 SQLite，可搜尋，可設定保留天數（預設 30 天，也可以永久）。錄音檔只有你要求時才留，
  而且有自己的清除排程。
- **取代規則**在模型之後才跑，可字面可正規表示式，有先後順序。字典是在模型之前跑的，模型有機會改回去；
  這一關則是沒得商量。
- **依 app 或網站切換模式。**「在這個 app、或這個網站裡，用那個模式。」網站是從最前面那個瀏覽器視窗讀出來的，
  不需要為每個瀏覽器寫一套 script。
- **HUD** 可以長在瀏海上、放在螢幕下方，或者不要。
- **插入方式**可選貼上或模擬打字，後者是給那些會吃掉合成 `⌘V` 的終端機和遊戲引擎用的。
  可以選要不要補一個空白、要不要按 Enter 送出，每個模式各自設定。剪貼簿事後會還原。
- **音訊**可以指定輸入裝置、靜音自動停止、錄音時把其他聲音壓掉。
- **備份**把模式、字典、取代規則、app 規則和偏好設定匯出成一個 JSON。裡面沒有 API key（key 在鑰匙圈），
  也沒有聽寫紀錄。
- 介面有六種語言，其中只有一種是母語者寫的，詳見 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 安裝

需要 **macOS 26 以上、Apple silicon**。舊系統沒有退路：辨識用的是 `SpeechAnalyzer`，macOS 26 之前不存在。

1. 到 [Releases](https://github.com/SammyLin/OpenTalkType/releases) 下載 `.dmg`，把 app 拖進「應用程式」。
2. 這份建置**沒有經過 Apple 公證**，所以第一次打開會被擋。在 app 上按右鍵選「打開」，或者執行：
   ```sh
   xattr -d com.apple.quarantine /Applications/OpenTalkType.app
   ```
3. 依提示給「麥克風」和「輔助使用」權限。
4. 系統設定 › 鍵盤 ›「按下地球儀鍵時」改成「不執行任何動作」，否則你一按住 `fn`，
   emoji 選擇器就蓋在聽寫上面跳出來。

每個 release 都附 `SHA256SUMS.txt`，想核對下載檔案可以用。

---

## 幾件不好聽但你該先知道的事

**它沒有公證。** 公證需要付費的 Apple Developer 帳號，這個專案目前沒有，就這麼單純，而且只影響第一次啟動。
之後的更新則是另一回事，而且經過驗證。每一版都用一把 EdDSA 金鑰簽章，那把鑰匙只存在兩個地方：
作者的鑰匙圈，以及這個 repo 的 Actions secrets。App 會拿編進 bundle 裡的公鑰比對，不符就拒絕安裝。
就算有人拿到了下載伺服器的控制權，也無法把更新換成別的東西。

這個區別對一個握有「輔助使用」權限的 app 特別重要：真正的風險不在下載本身，
而在於什麼東西有資格取代一個被允許監看你每一次按鍵的程式。
自動檢查仍然預設關閉——一個在你還沒同意任何事情之前就自己連外的 app，是在沒問過你的情況下做決定。
一個握有輔助使用權限的 app 自動安裝沒人驗證過的新版本，那不叫方便，那叫幫人送鍵盤側錄器，所以它刻意不做。

**「輔助使用」這個權限，實質上就是「看得到你每一次按鍵」。** `CGEvent` tap 本來就是這麼一回事，
`fn` 也只能這樣才偵測得到；同一個權限也用來讀 Ask 模式要處理的選取文字、以及把結果貼回去。
這種事不該只憑一份 README 相信。用到它的程式碼就一個檔案：
[`OpenTalkType/Input.swift`](OpenTalkType/Input.swift)，tap callback 裡面只做狀態切換，
而整個 app 除了 `LLM.swift` 和更新檢查之外沒有任何連外的程式碼。

**地球儀鍵一定要改成不執行任何動作。** 不改的話，你按住 `fn` 的同時 emoji 選擇器也會跳出來。
app 刻意不去攔截 `fn` 事件：WindowServer 更新修飾鍵狀態的位置在 event tap 之前，
攔下來會讓整個系統以為 `fn` 一直被按著。

**重新建置會讓輔助使用權限默默失效。** 本機建置用的是 ad-hoc 簽章，每次重建身分都不一樣，
macOS 會把授權作廢卻不告訴你，系統設定裡那個勾勾看起來還是打著的。症狀是貼上突然不動了。
到設定 › Permissions 按「重新要求權限」，或者把 app 從輔助使用清單移掉再加回去。

**安全輸入狀態下貼不了。** 密碼欄位、或終端機開了 Secure Keyboard Entry，整個系統會進入 secure input，
所有合成事件都送不進去。這時文字會留在剪貼簿，app 會明講發生什麼事，而不是裝作沒事。

---

## 自己建置

沒有第三方相依、沒有套件管理步驟、沒有東西要解析。

```sh
xcodegen generate
open OpenTalkType.xcodeproj
```

沒裝 xcodegen 的話先 `brew install xcodegen`。建置需要 Xcode 26。簽章是 ad-hoc，所以不需要 Apple 開發者帳號。

### 自我測試

GUI 沒辦法靠讀原始碼驗證，所以 app 自己就是測試工具：

```sh
OpenTalkType.app/Contents/MacOS/OpenTalkType --selftest
```

173 項純邏輯檢查：不開視窗、不碰麥克風、不連網路、不要權限。一行一個 `PASS` 或 `FAIL`，
全過才回傳 0。CI 每次推送都在 `macos-26` 上跑一次，外加對 stdio server 做一次真正的 MCP 握手；
release 流程還會再對 `.dmg` 裡那個實際的執行檔跑一次。

---

## 授權

MIT，見 [LICENSE](LICENSE)。

## 致謝

瀏海 HUD 的形狀——面板從螢幕缺口「長出來」而不是像塊板子掛在下面——是從
[sk-ruban/notchi](https://github.com/sk-ruban/notchi) 學來的。
