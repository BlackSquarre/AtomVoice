[English](README.md) | [简体中文](README-zh-Hans.md) | **繁體中文** | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice（原子微語）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

輕量級 macOS 選單列語音輸入法。按住 **Fn** 鍵錄音，鬆開後文字自動注入當前輸入框。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 隱私優先
所有語音辨識均透過 Apple 語音辨識框架**在本機完成**，音訊不會發送到任何伺服器（除非主動開啟 LLM 文本優化）。

### ⚡ 極致輕量
約 3 MB，閒置時 CPU 佔用趨近於零，無背景行程。

---

## 功能特色

- **按住 Fn 鍵**錄音，鬆開即將文字注入當前輸入框
- **串流轉錄** — 基於 Apple 語音辨識框架，預設繁體中文
- **5 頻段即時頻譜波形** — 100–6000 Hz，左低頻右高頻，由 Accelerate FFT 驅動
- **本地自動標點** — 根據語氣詞補全句末標點，無需連網
- **LLM 文本優化** — 接入 OpenAI 相容 API，自動糾錯（如配森→Python）；內建 9 個服務商預設，列表可自由編輯
- **動態島風格動畫** — 120Hz 真實彈簧物理積分 + 高斯模糊；「優化中」時全膠囊掃光效果
- **深色/淺色模式自動適應** — macOS 26 液態玻璃，舊系統毛玻璃降級
- **7 種介面語言** — 簡體中文、繁體中文、English、日本語、한국어、Español、Français、Deutsch
- **CJK 輸入法相容** — 注入前自動切換輸入來源，防止中文輸入法攔截

## 系統需求

- macOS 13 Ventura 及以上
- 需要權限：**輔助功能**、**麥克風**、**語音辨識**

## 安裝

**從 Release 下載（推薦）**

前往 [Releases](https://github.com/BlackSquarre/AtomVoice/releases)，下載對應架構的 zip，解壓後拖入應用程式資料夾。

**從原始碼建構**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ 簽名提示

臨時簽名，未經 Apple 公證。首次開啟時：

1. 右鍵點擊 `AtomVoice.app` → **開啟** → 點擊**開啟**
2. 或前往**系統設定 → 隱私與安全性** → **仍然開啟**
3. 或在終端機執行：`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 說明 |
|------|------|
| 按住 Fn | 開始錄音 |
| 鬆開 Fn | 停止錄音，文字自動注入 |
| 點擊選單列圖示 | 切換語言 / 動畫 / LLM 設定 |

## LLM 優化設定

選單列 → **LLM 文本優化** → **設定** — 選擇服務商預設或自訂新增，填入 API Key 和模型名稱。

內建預設：OpenAI / DeepSeek / Moonshot (Kimi) / 阿里雲百煉 (Qwen) / 智譜 AI (GLM) / 零一萬物 (Yi) / Groq / Ollama（本機）

## 建構指令

```bash
make build    # 建構 .app bundle
make run      # 建構並啟動
make install  # 安裝到 /Applications
make release  # 建構 Universal + AppleSilicon + Intel 三個版本
make clean    # 清理建構產物
```

## License

MIT
