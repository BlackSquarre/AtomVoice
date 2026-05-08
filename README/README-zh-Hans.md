[English](../README.md) | **简体中文** | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# 原子微语（AtomVoice）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">按下即说，言出即文。</h3>
<p align="center">轻盈、隐私优先的语音输入，畅达任意 Mac 应用，不限时长。</p>



---

### 🔒 隐私优先
语音识别默认在**本地完成**——可选 Apple 语音识别或内置的 Sherpa-ONNX 本地引擎。除非你主动启用 LLM 文本优化，否则音频永远不会离开你的 Mac。

### ⚡ 极致轻量
应用包体积小，空闲时 CPU 占用趋近于零，无后台守护进程。Sherpa 模型按需下载，系统内存吃紧时会自动释放。

---

## 功能特性

### 录音与触发
- **长按说话 / 单击说话** — 任选其一，可配合静音自动停止
- **自定义触发键** — 选一个最顺手的修饰键即可
- **录音中快捷键** — 一键取消、立即上屏跳过 LLM、或一键以指定标点收尾
- **切换前台应用自动取消**（仅长按模式）

### 识别引擎
- **Apple 语音识别** — 流式识别，可选设备端模式；**滚动分段**突破 SFSpeechRecognizer 1 分钟硬限制
- **Sherpa-ONNX** — 完全离线的本地引擎，首次使用自动下载模型，含本地标点模型
- **8 种识别语言** — English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch

### 文字输出
- **Apple 实时上屏** — 录音过程中已完成的句子自动逐句注入，无需等到松手
- **智能标点** — 本地启发式标点引擎（多语言）；光标后已有标点时自动跳过
- **中日韩输入法兼容** — 粘贴前临时切到 ASCII 布局，完成后恢复
- **LLM 文本优化** — 同时支持 OpenAI 兼容协议与 **Anthropic**，流式预览；内置 10 个服务商预设 + 可自由编辑的自定义列表；自带多语言默认 prompt，也可自定义

### 界面与动画
- **5 频段 FFT 频谱波形**，针对人声共振峰调校（100–4200 Hz），由 Accelerate 驱动
- **三种动画风格** — 灵动岛（Spotlight 式弹性 + 高斯模糊）/ 极简 / 无；三档速度，自适应 ProMotion 120Hz
- **液态玻璃**（macOS 26）/ **毛玻璃**（macOS 14/15）
- **8 种界面语言**，跟随系统自动选择

### 系统集成
- **自动更新** — 从 GitHub Releases 拉取，下载后做代码签名验证（可选 Beta 通道）
- **开机自启动**（SMAppService）
- **音频输入设备选择** — 任意系统麦克风可选
- **录音时降低系统音量**（可选）
- **单实例保护** — 启动时自动关闭旧实例

## 系统要求

- **macOS 14 Sonoma 及以上**
- 需要权限：**辅助功能**、**麦克风**、**语音识别**

## 安装

**从 Release 下载（推荐）**

前往 [Releases](https://github.com/BlackSquarre/AtomVoice/releases)，下载对应架构的 zip，解压后拖入应用程序文件夹。每次发版提供 Universal / Apple Silicon / Intel 三种架构。

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**从源码构建**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ 签名提示

临时签名，未经 Apple 公证。首次打开时：

1. 右键点击 `AtomVoice.app` → **打开** → 点击**打开**
2. 或前往**系统设置 → 隐私与安全性** → **仍然打开**
3. 或在终端运行：`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 说明 |
|------|------|
| 长按触发键 | 开始录音（长按模式） |
| 松开触发键 | 停止录音并注入文字 |
| 单击触发键 | 开始 / 停止录音（单击模式） |
| 录音中按 `ESC` | 取消，不上屏 |
| 录音中按 `空格` / `退格` | 立即上屏，跳过 LLM |
| 录音中输入标点 | 立即上屏并附加该标点 |
| 点击菜单栏图标 | 切换引擎 / 语言 / 模式 / 动画 / LLM |

## LLM 优化配置

菜单栏 → **LLM 文本优化** → **设置** — 选择服务商预设或自定义添加，填入 API Key 和模型名称。流式输出会在胶囊里实时预览。

内置预设：**OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / 阿里云百炼 (Qwen) / 智谱 AI (GLM) / 零一万物 (Yi) / Groq / **Ollama（本地）** / 自定义。

默认 system prompt 针对口述润色专门调校（修复同音字、错认的产品名/API 名、口头禅、标点），并根据识别语言自动切换。也可以填自己的 prompt 覆盖。

## License

Apache License 2.0
