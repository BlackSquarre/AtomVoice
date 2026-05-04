[简体中文](README/README-zh-Hans.md) | [繁體中文](README/README-zh-Hant.md) | [日本語](README/README-ja.md) | [한국어](README/README-ko.md) | [Español](README/README-es.md) | [Français](README/README-fr.md) | [Deutsch](README/README-de.md) | **English**

# AtomVoice

<p align="center"><img src="README/AppIcon-1024.png" width="128"></p>

A lightweight macOS menu bar voice input app. Hold **Fn** to record, release to inject transcribed text into any focused input field.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 Privacy First
All speech recognition runs **on-device** via Apple's Speech Recognition framework. No audio is ever sent to any server unless you explicitly enable LLM Refinement.

### ⚡ Lightweight
~3 MB app bundle. Near-zero CPU when idle. No background daemons.

---

## Features

- **Hold Fn** to record, release to inject text into any input field
- **Streaming transcription** — Apple Speech Recognition, default Simplified Chinese
- **5-band FFT spectrum waveform** — 100–6000 Hz, low→high left→right, driven by Accelerate framework
- **Auto punctuation** — local rule engine adds sentence-ending marks, no internet required
- **LLM Refinement** — OpenAI-compatible API corrects mis-transcribed terms (e.g. 配森→Python); 9 preset providers + fully editable custom list
- **Dynamic Island animation** — real spring physics at 120 Hz with Gaussian blur; shimmer sweep during refinement
- **Dark/Light mode** — Liquid Glass on macOS 26, Visual Effect blur on older systems
- **7 UI languages** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch
- **CJK IME compatible** — auto-switches to ASCII input source before paste

## Requirements

- macOS 13 Ventura or later
- Permissions required: **Accessibility**, **Microphone**, **Speech Recognition**

## Installation

**From Release (recommended)**

Download from [Releases](https://github.com/BlackSquarre/AtomVoice/releases), unzip, drag to Applications.

**Build from source**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Gatekeeper Warning

Ad-hoc signed (not notarized). On first open:

1. Right-click `AtomVoice.app` → **Open** → click **Open**
2. Or go to **System Settings → Privacy & Security** → **Open Anyway**
3. Or run: `xattr -cr /Applications/AtomVoice.app`

## Usage

| Action | Result |
|--------|--------|
| Hold Fn | Start recording |
| Release Fn | Stop and inject text |
| Menu bar icon | Switch language / animation / LLM settings |

## LLM Refinement Setup

Menu bar → **LLM Refinement** → **Settings** — select a provider preset or add your own, enter API key and model name.

Built-in presets: OpenAI / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / Ollama (local)

## Build Commands

```bash
make build    # Build .app bundle
make run      # Build and launch
make install  # Install to /Applications
make release  # Build Universal + AppleSilicon + Intel packages
make clean    # Clean build artifacts
```

## License

MIT
