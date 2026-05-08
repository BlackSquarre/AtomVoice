[English](../README.md) | [简体中文](README-zh-Hans.md) | **繁體中文** | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# 原子微語（AtomVoice）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">按下即說,言出即文。</h3>
<p align="center">輕盈、隱私優先的語音輸入,暢達任意 Mac 應用程式,不限時長。</p>



---

### 🔒 隱私優先
語音辨識預設在**本機完成**——可選 Apple 語音辨識或內建的 Sherpa-ONNX 本機引擎。除非你主動啟用 LLM 文字優化,音訊永遠不會離開你的 Mac。

### ⚡ 極致輕量
App 體積精簡,閒置時 CPU 占用趨近於零,無背景守護程序。Sherpa 模型按需下載,系統記憶體吃緊時會自動釋放。

---

## 功能特性

### 錄音與觸發
- **長按說話 / 單擊說話** — 任選其一,可搭配靜音自動停止
- **自訂觸發鍵** — 選一個最順手的修飾鍵即可
- **錄音中快捷鍵** — 一鍵取消、立即上屏跳過 LLM、或一鍵以指定標點收尾
- **切換前景 App 自動取消**(僅長按模式)

### 辨識引擎
- **Apple 語音辨識** — 串流辨識,可選裝置端模式;**滾動分段**突破 SFSpeechRecognizer 1 分鐘硬限制
- **Sherpa-ONNX** — 完全離線的本機引擎,首次使用自動下載模型,內含本機標點模型
- **8 種辨識語言** — English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch

### 文字輸出
- **Apple 即時上屏** — 錄音過程中已完成的句子自動逐句注入,無需等到鬆手
- **智慧標點** — 本機啟發式標點引擎(多語言);游標後已有標點時自動跳過
- **中日韓輸入法相容** — 貼上前暫時切到 ASCII 配置,完成後復原
- **LLM 文字優化** — 同時支援 OpenAI 相容協定與 **Anthropic**,串流預覽;內建 10 個服務商預設 + 可自由編輯的自訂清單;自帶多語言預設 prompt,也可自訂

### 介面與動畫
- **5 頻段 FFT 頻譜波形**,針對人聲共振峰調校(100–4200 Hz),由 Accelerate 驅動
- **三種動畫風格** — 靈動島(Spotlight 式彈性 + 高斯模糊)/ 極簡 / 無;三檔速度,自動適配 ProMotion 120Hz
- **液態玻璃**(macOS 26)/ **毛玻璃**(macOS 14/15)
- **8 種介面語言**,跟隨系統自動選擇

### 系統整合
- **自動更新** — 從 GitHub Releases 拉取,下載後做程式碼簽章驗證(可選 Beta 頻道)
- **開機自動啟動**(SMAppService)
- **音訊輸入裝置選擇** — 任意系統麥克風可選
- **錄音時降低系統音量**(可選)
- **單一執行個體保護** — 啟動時自動關閉舊執行個體

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
make install
```

## ⚠️ 簽章提示

臨時簽章,未經 Apple 公證。首次開啟時:

1. 右鍵點擊 `AtomVoice.app` → **打開** → 點選**打開**
2. 或前往**系統設定 → 隱私權與安全性** → **仍要打開**
3. 或在終端機執行:`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 說明 |
|------|------|
| 長按觸發鍵 | 開始錄音(長按模式) |
| 鬆開觸發鍵 | 停止錄音並注入文字 |
| 單擊觸發鍵 | 開始 / 停止錄音(單擊模式) |
| 錄音中按 `ESC` | 取消,不上屏 |
| 錄音中按 `空白鍵` / `退格鍵` | 立即上屏,跳過 LLM |
| 錄音中輸入標點 | 立即上屏並附加該標點 |
| 點擊選單列圖示 | 切換引擎 / 語言 / 模式 / 動畫 / LLM |

## LLM 優化設定

選單列 → **LLM 文字優化** → **設定** — 選擇服務商預設或自訂新增,填入 API Key 與模型名稱。串流輸出會在膠囊裡即時預覽。

內建預設:**OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / 阿里雲百煉 (Qwen) / 智譜 AI (GLM) / 零一萬物 (Yi) / Groq / **Ollama(本機)** / 自訂。

預設 system prompt 針對口述潤色專門調校(修復同音字、錯認的產品名/API 名、口頭禪、標點),並根據辨識語言自動切換。也可以填自己的 prompt 覆寫。

## License

Apache License 2.0
