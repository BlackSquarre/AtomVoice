# VoiceInput

**中文** | [English](#english)

一款优雅的 macOS 菜单栏语音输入法，按住 Fn 键即可将语音实时转为文字并注入任意输入框。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## 功能特性

- **一键录音** — 按住 Fn 键开始录音，松开即停止并自动注入文字
- **流式转录** — 基于 Apple Speech Recognition 框架，实时显示识别结果
- **多语言支持** — 简体中文（默认）、繁体中文、英语、日语、韩语
- **频谱波形** — 5 根竖条实时显示人声频段（100–6000 Hz）能量，左低频右高频
- **自动标点** — 本地规则引擎根据语气词自动补全句末标点，无需联网
- **LLM 优化** — 接入 OpenAI 兼容 API，自动修复语音识别错误（如「配森」→「Python」）
- **深浅色自适应** — 胶囊弹窗自动跟随系统外观
- **剪贴板安全** — 注入完成后自动恢复原剪贴板内容
- **CJK 输入法兼容** — 注入前自动切换至 ASCII 输入源，防止中文输入法拦截

## 系统要求

- macOS 14 Sonoma 及以上
- 需要授权：**辅助功能**、**麦克风**、**语音识别**

## 安装

```bash
git clone https://github.com/BlackSquarre/VoiceInputAlpha.git
cd VoiceInputAlpha
make build      # 构建 .app
make install    # 安装到 /Applications
```

首次运行请在**系统设置 → 隐私与安全性**中依次授权辅助功能、麦克风和语音识别。

## 使用方法

| 操作 | 说明 |
|------|------|
| 按住 Fn | 开始录音 |
| 松开 Fn | 停止录音，文字自动注入当前输入框 |
| 点击菜单栏图标 | 切换语言 / 开启 LLM 优化 / 退出 |

## LLM 优化配置

在菜单栏 → **LLM 文本优化 → 设置** 中填入：

- **API 地址**：OpenAI 兼容的 base URL（默认 `https://api.openai.com/v1`）
- **API 密钥**：你的 API Key
- **模型**：如 `gpt-4o-mini`、`deepseek-chat` 等

LLM 仅做保守纠错，不改写、不润色、不删减内容。

## 构建命令

```bash
make build    # 构建 .app bundle（含签名）
make run      # 构建并启动
make install  # 安装到 /Applications
make clean    # 清理构建产物
```

## 项目结构

```
Sources/VoiceInput/
├── AppDelegate.swift          # 应用入口，录音流水线
├── FnKeyMonitor.swift         # Fn 键全局监听（CGEvent tap）
├── AudioEngine.swift          # AVAudioEngine + FFT 频段分析
├── SpeechRecognizer.swift     # Apple Speech Recognition 流式识别
├── CapsuleWindow.swift        # 胶囊弹窗（NSPanel + 动画）
├── WaveformView.swift         # 频谱波形视图（正弦波驱动）
├── PunctuationProcessor.swift # 本地自动标点规则引擎
├── LLMRefiner.swift           # OpenAI 兼容 API 纠错
├── TextInjector.swift         # 剪贴板注入 + 输入法切换
├── MenuBarController.swift    # 菜单栏控制
└── SettingsWindow.swift       # 设置窗口
```

---

<a name="english"></a>

# VoiceInput

[中文](#voiceinput) | **English**

An elegant macOS menu bar voice input app. Hold the Fn key to transcribe speech and inject text into any input field.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

- **Hold-to-record** — Hold Fn to record, release to stop and inject text automatically
- **Streaming transcription** — Apple Speech Recognition framework with real-time partial results
- **Multi-language** — Simplified Chinese (default), Traditional Chinese, English, Japanese, Korean
- **Spectrum waveform** — 5 bars visualizing voice frequency bands (100–6000 Hz), low to high left to right
- **Auto punctuation** — Local rule engine adds sentence-ending punctuation based on tone words, no internet required
- **LLM refinement** — OpenAI-compatible API corrects speech recognition errors (e.g. "Pei Sen" → "Python")
- **Dark/Light mode** — Capsule window adapts automatically to system appearance
- **Clipboard safety** — Original clipboard content is restored after injection
- **CJK IME compatible** — Temporarily switches to ASCII input source before pasting to prevent CJK input methods from intercepting Cmd+V

## Requirements

- macOS 14 Sonoma or later
- Permissions required: **Accessibility**, **Microphone**, **Speech Recognition**

## Installation

```bash
git clone https://github.com/BlackSquarre/VoiceInputAlpha.git
cd VoiceInputAlpha
make build      # Build .app bundle
make install    # Install to /Applications
```

On first launch, grant Accessibility, Microphone and Speech Recognition permissions in **System Settings → Privacy & Security**.

## Usage

| Action | Result |
|--------|--------|
| Hold Fn | Start recording |
| Release Fn | Stop recording, inject transcribed text into focused field |
| Click menu bar icon | Switch language / toggle LLM / quit |

## LLM Refinement Setup

Go to menu bar → **LLM 文本优化 → 设置** and fill in:

- **API Base URL**: any OpenAI-compatible endpoint (default: `https://api.openai.com/v1`)
- **API Key**: your API key
- **Model**: e.g. `gpt-4o-mini`, `deepseek-chat`

The LLM only performs conservative error correction — it never rewrites, rephrases, or removes content.

## Build Commands

```bash
make build    # Build signed .app bundle
make run      # Build and launch
make install  # Install to /Applications
make clean    # Clean build artifacts
```

## Project Structure

```
Sources/VoiceInput/
├── AppDelegate.swift          # App entry point, recording pipeline
├── FnKeyMonitor.swift         # Global Fn key monitoring (CGEvent tap)
├── AudioEngine.swift          # AVAudioEngine + FFT frequency band analysis
├── SpeechRecognizer.swift     # Apple Speech Recognition streaming
├── CapsuleWindow.swift        # Capsule panel (NSPanel + animations)
├── WaveformView.swift         # Spectrum waveform view (sine-wave driven)
├── PunctuationProcessor.swift # Local auto-punctuation rule engine
├── LLMRefiner.swift           # OpenAI-compatible API error correction
├── TextInjector.swift         # Clipboard injection + IME switching
├── MenuBarController.swift    # Menu bar controller
└── SettingsWindow.swift       # Settings window
```

## License

MIT
