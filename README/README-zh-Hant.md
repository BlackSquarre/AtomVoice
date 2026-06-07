<p align="center">
  <img src="atomvoicepreview.webp" alt="AtomVoice usage demo" width="960">
</p>

---

[English](../README.md) | [简体中文](README-zh-Hans.md) | **繁體中文** | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# 原子微語（AtomVoice）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">按下即說,言出即文。</h3>
<p align="center">輕盈、隱私優先的語音輸入,暢達任意 Mac 應用程式,不限時長。</p>



---

### 🔒 隱私優先
AtomVoice 會清楚告訴你哪些功能會用到雲端，由你決定是否啟用。Sherpa-ONNX 完全離線執行；Apple 語音辨識在目前語言支援時可使用離線本機辨識；豆包雲端辨識和 LLM 文字優化只有在你手動啟用後才會使用。AtomVoice 不運行自己的伺服器，不保存錄音，也不保存辨識歷史。

### ⚡ 極致輕量
安裝包不到 3 MB，沒有背景守護程序。Sherpa-ONNX 本機辨識可使用 CoreML 後端，減少 CPU 壓力和耗電；Sherpa 執行庫、辨識模型和標點模型按需下載，大模型也可在閒置一段時間後或系統記憶體嚴重吃緊時釋放。

### ⌨️ 輸入習慣相容
AtomVoice 不會接管系統輸入法，不改變原本的打字習慣；你可以繼續使用自己熟悉的中英文輸入法、快捷鍵和偏好。想打字就打字，想說話就說話。寫長句、補充想法、跨 App 輸入時，可以隨時用語音接上。

---

## 功能特性

### 錄音與觸發
- **長按說話 / 單擊說話** — 任選其一,可搭配由辨識文字驅動的靜音自動停止,降低安靜說話或嘈雜環境下的誤截斷
- **自訂觸發鍵** — 選一個最順手的修飾鍵即可
- **錄音中快捷鍵** — 一鍵取消、立即上屏跳過 LLM、或一鍵以指定標點收尾
- **耳機語音控制 (Beta)** — 用耳機播放/暫停鍵控制語音輸入；已驗證 USB 耳機 / DAC 控制鍵和 3.5 mm 耳機按鍵：單擊跟隨目前輸入模式，長按說話，雙擊送出 Return
- **切換前景 App 自動取消**(僅長按模式)

### 辨識引擎
- **Apple 語音辨識** — 系統引擎，支援串流辨識、可選裝置端模式，並透過**滾動分段**突破 SFSpeechRecognizer 1 分鐘硬限制
- **Sherpa-ONNX** — 完全離線的本機引擎，支援按語言選擇模型預設、CPU/CoreML 後端、按需下載執行庫/辨識模型/標點模型、閒置自動釋放，以及匯入第三方模型
- **豆包雲端辨識** — 可選火山引擎串流辨識，API Key 保存到鑰匙圈，支援 ITN、智慧標點、語意順滑、可選二遍辨識；雲端失敗時可回退到 Apple 語音
- **8 種介面與辨識語言** — English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch；Sherpa 對沒有內建預設的語言也支援匯入第三方模型

### 文字輸出
- **Apple 即時上屏** — 錄音過程中已完成的句子自動逐句注入,無需等到鬆手
- **智慧標點** — 本機啟發式標點引擎(多語言);游標後已有標點時自動跳過
- **中日韓輸入法相容** — 貼上前暫時切到 ASCII 配置,完成後復原
- **LLM 文字優化 (Beta)** — 僅處理辨識文字，支援 OpenAI 相容協定與 **Anthropic**,串流預覽;內建 10 個服務商預設 + 可自由編輯的自訂清單;自帶多語言預設 prompt,也可自訂

### 介面與動畫
- **5 頻段 FFT 頻譜波形**,針對人聲共振峰調校(100–4200 Hz),由 Accelerate 驅動
- **三種動畫風格** — 靈動島(Spotlight 式彈性 + 高斯模糊)/ 極簡 / 無;三檔速度,自動適配 ProMotion 120Hz
- **液態玻璃**(macOS 26)/ **毛玻璃**(macOS 14/15)
- **8 種介面語言**,跟隨系統自動選擇

### 系統整合
- **首次啟動精靈** — 引導權限、輸入方式和辨識引擎選擇
- **自動更新** — 從 GitHub Releases 拉取，並做 SHA256 與程式碼簽章驗證(可選 Beta 頻道)
- **開機自動啟動**(SMAppService)
- **音訊輸入裝置選擇** — 任意系統麥克風可選
- **音訊路由恢復** — 錄音中插拔耳機、切換 AirPods 或輸入裝置時可自動恢復，並按不同辨識引擎自動重採樣
- **錄音時降低系統音量**(可選)
- **單一執行個體保護** — 啟動時自動關閉舊執行個體，減少多個執行個體同時搶占耳機按鍵事件

## 系統需求

- **macOS 14 Sonoma 及以上**
- 需要權限:**輔助使用**、**麥克風**、**語音辨識**

## 安裝

**從 Release 下載(建議)**

前往 [Releases](https://github.com/BlackSquarre/AtomVoice/releases),下載對應架構的 zip,解壓縮後拖入應用程式資料夾。每次發版提供 Universal / Apple Silicon / Intel 三種架構。

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**從原始碼建置**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make dev
open dist/Test/AtomVoice.app
```

架構和本地化覆蓋檢查可執行：

```bash
make test
make lint-loc
```

`make lint-loc` 會掃描 `loc("key")` 與 8 個本地化目錄，避免新增介面文案漏翻譯。

Makefile 會使用其中設定的 Apple Development 憑證打包簽章；如果在另一台 Mac 建置，需要先改成自己的簽章身分。

## ⚠️ 簽章提示

未經 Apple 公證。首次開啟時:

1. 右鍵點擊 `AtomVoice.app` → **打開** → 點選**打開**
2. 或前往**系統設定 → 隱私權與安全性** → **仍要打開**
3. 或在終端機執行:`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 說明 |
|------|------|
| 長按觸發鍵 | 開始錄音(長按模式) |
| 鬆開觸發鍵 | 停止錄音並注入文字 |
| 單擊觸發鍵 | 開始 / 停止錄音(單擊模式) |
| 錄音中點擊膠囊 | 停止錄音並上屏 |
| 錄音中按 `ESC` | 取消,不上屏 |
| 錄音中按 `空白鍵` / `退格鍵` | 立即上屏,跳過 LLM |
| 錄音中輸入標點 | 立即上屏並附加該標點 |
| 耳機播放/暫停鍵（可選，Beta） | 單擊跟隨輸入模式，長按錄音，雙擊送出 Return |
| 點擊選單列圖示 | 切換引擎 / 語言 / 輸入模式 / 動畫 / 辨識設定 / LLM |

## 辨識引擎設定

- **Apple 語音辨識** 開箱即用；目前語言支援時可啟用裝置端辨識。
- **Sherpa-ONNX** 在 **辨識引擎設定 → Sherpa 本機辨識** 中設定，可選擇語言、模型預設、CPU/CoreML 後端、自動釋放時間，也可匯入第三方模型包。
- **豆包雲端辨識** 在 **辨識引擎設定 → 豆包雲端辨識** 中設定，填入火山引擎 API Key，選擇模型版本，並可保留或修改 WebSocket Endpoint。首次切換到豆包時會確認雲端音訊處理。

## LLM 優化 (Beta) 設定

選單列 → **LLM 文字優化 (Beta)** → **設定** — 選擇服務商預設或自訂新增,填入 API Key 與模型名稱。串流輸出會在膠囊裡即時預覽。

內建預設:**OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / 阿里雲百煉 (Qwen) / 智譜 AI (GLM) / 零一萬物 (Yi) / Groq / **Ollama(本機)** / 自訂。

預設 system prompt 針對口述潤色專門調校(修復同音字、錯認的產品名/API 名、口頭禪、標點),並根據辨識語言自動切換。也可以填自己的 prompt 覆寫。LLM 文字優化只會把辨識文字傳送給你選擇的服務商，不會傳送音訊。

## License

Apache License 2.0

隱私政策：[繁體中文](privacy/PRIVACY-zh-Hant.md) / [English](privacy/PRIVACY-en.md)。
