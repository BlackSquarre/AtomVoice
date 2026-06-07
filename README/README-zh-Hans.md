<p align="center">
  <img src="atomvoicepreview-30fps.apng" alt="AtomVoice usage demo" width="960">
</p>

---

[English](../README.md) | **简体中文** | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# 原子微语（AtomVoice）

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">按下即说，言出即文。</h3>
<p align="center">轻盈、隐私优先的语音输入，畅达任意 Mac 应用，不限时长。</p>



---

### 🔒 隐私优先
AtomVoice 会明确告诉你哪些功能会用到云端，由你决定是否开启。Sherpa-ONNX 完全离线运行；Apple 语音识别在当前语言支持时可用离线本机识别；豆包云端识别和 LLM 文本优化只有在你手动开启后才会使用。AtomVoice 不运行自己的服务器，不保存录音，也不保存识别历史。

### ⚡ 极致轻量
安装包不到 3 MB，没有后台守护进程。Sherpa-ONNX 本地识别可使用 CoreML 后端，减少 CPU 压力和耗电；Sherpa 运行库、识别模型和标点模型按需下载，大模型也可在空闲一段时间后或系统内存严重吃紧时释放。

### ⌨️ 输入习惯兼容
AtomVoice 不会接管系统输入法，不改变原来的打字习惯；你可以继续使用自己熟悉的中英文输入法、快捷键和偏好。想打字就打字，想说话就说话。写长句、补充想法、跨 App 输入时，可以随时用语音接上。

---

## 功能特性

### 录音与触发
- **长按说话 / 单击说话** — 任选其一，可配合由识别文本驱动的静音自动停止，降低安静说话或嘈杂环境下的误截断
- **自定义触发键** — 选一个最顺手的修饰键即可
- **录音中快捷键** — 一键取消、立即上屏跳过 LLM、或一键以指定标点收尾
- **耳机语音控制 (Beta)** — 用耳机播放/暂停键控制语音输入；已验证 USB 耳机 / DAC 控制键和 3.5 mm 耳机按键：单击跟随当前输入模式，长按说话，双击发送回车
- **切换前台应用自动取消**（仅长按模式）

### 识别引擎
- **Apple 语音识别** — 系统引擎，支持流式识别、可选设备端模式，并通过**滚动分段**突破 SFSpeechRecognizer 1 分钟硬限制
- **Sherpa-ONNX** — 完全离线的本地引擎，支持按语言选择模型预设、CPU/CoreML 后端、按需下载运行库/识别模型/标点模型、空闲自动释放，以及导入第三方模型
- **豆包云端识别** — 可选火山引擎流式识别，API Key 保存到钥匙串，支持 ITN、智能标点、语义顺滑、可选二遍识别；云端失败时可回退到 Apple 语音
- **8 种界面与识别语言** — English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch；Sherpa 对没有内置预设的语言也支持导入第三方模型

### 文字输出
- **Apple 实时上屏** — 录音过程中已完成的句子自动逐句注入，无需等到松手
- **智能标点** — 本地启发式标点引擎（多语言）；光标后已有标点时自动跳过
- **中日韩输入法兼容** — 粘贴前临时切到 ASCII 布局，完成后恢复
- **LLM 文本优化 (Beta)** — 仅处理识别文本，支持 OpenAI 兼容协议与 **Anthropic**，流式预览；内置 10 个服务商预设 + 可自由编辑的自定义列表；自带多语言默认 prompt，也可自定义

### 界面与动画
- **5 频段 FFT 频谱波形**，针对人声共振峰调校（100–4200 Hz），由 Accelerate 驱动
- **三种动画风格** — 灵动岛（Spotlight 式弹性 + 高斯模糊）/ 极简 / 无；三档速度，自适应 ProMotion 120Hz
- **液态玻璃**（macOS 26）/ **毛玻璃**（macOS 14/15）
- **8 种界面语言**，跟随系统自动选择

### 系统集成
- **首次启动向导** — 引导权限、输入方式和识别引擎选择
- **自动更新** — 从 GitHub Releases 拉取，并做 SHA256 与代码签名验证（可选 Beta 通道）
- **开机自启动**（SMAppService）
- **音频输入设备选择** — 任意系统麦克风可选
- **音频路由恢复** — 录音中插拔耳机、切换 AirPods 或输入设备时可自动恢复，并按不同识别引擎自动重采样
- **录音时降低系统音量**（可选）
- **单实例保护** — 启动时自动关闭旧实例，减少多个实例同时抢占耳机按键事件

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
make dev
open dist/Test/AtomVoice.app
```

架构和本地化覆盖检查可运行：

```bash
make test
make lint-loc
```

`make lint-loc` 会扫描 `loc("key")` 与 8 个本地化目录，避免新增界面文案漏翻译。

Makefile 会用其中配置的 Apple Development 证书打包签名；如果在另一台 Mac 构建，需要先改成自己的签名身份。

## ⚠️ 签名提示

未经 Apple 公证。首次打开时：

1. 右键点击 `AtomVoice.app` → **打开** → 点击**打开**
2. 或前往**系统设置 → 隐私与安全性** → **仍然打开**
3. 或在终端运行：`xattr -cr /Applications/AtomVoice.app`

## 使用方法

| 操作 | 说明 |
|------|------|
| 长按触发键 | 开始录音（长按模式） |
| 松开触发键 | 停止录音并注入文字 |
| 单击触发键 | 开始 / 停止录音（单击模式） |
| 录音中点击胶囊 | 停止录音并上屏 |
| 录音中按 `ESC` | 取消，不上屏 |
| 录音中按 `空格` / `退格` | 立即上屏，跳过 LLM |
| 录音中输入标点 | 立即上屏并附加该标点 |
| 耳机播放/暂停键（可选，Beta） | 单击跟随输入模式，长按录音，双击发送回车 |
| 点击菜单栏图标 | 切换引擎 / 语言 / 输入模式 / 动画 / 识别设置 / LLM |

## 识别引擎配置

- **Apple 语音识别** 开箱即用；当前语言支持时可开启设备端识别。
- **Sherpa-ONNX** 在 **识别引擎设置 → Sherpa 本地识别** 中配置，可选择语言、模型预设、CPU/CoreML 后端、自动释放时间，也可导入第三方模型包。
- **豆包云端识别** 在 **识别引擎设置 → 豆包云端识别** 中配置，填入火山引擎 API Key，选择模型版本，并可保留或修改 WebSocket Endpoint。首次切换到豆包时会确认云端音频处理。

## LLM 优化 (Beta) 配置

菜单栏 → **LLM 文本优化 (Beta)** → **设置** — 选择服务商预设或自定义添加，填入 API Key 和模型名称。流式输出会在胶囊里实时预览。

内置预设：**OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / 阿里云百炼 (Qwen) / 智谱 AI (GLM) / 零一万物 (Yi) / Groq / **Ollama（本地）** / 自定义。

默认 system prompt 针对口述润色专门调校（修复同音字、错认的产品名/API 名、口头禅、标点），并根据识别语言自动切换。也可以填自己的 prompt 覆盖。LLM 文本优化只会把识别文本发送给你选择的服务商，不会发送音频。

## License

Apache License 2.0

隐私政策：[简体中文](privacy/PRIVACY-zh-Hans.md) / [English](privacy/PRIVACY-en.md)。
