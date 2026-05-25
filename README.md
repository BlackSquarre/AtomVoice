**English** | [简体中文](README/README-zh-Hans.md) | [繁體中文](README/README-zh-Hant.md) | [日本語](README/README-ja.md) | [한국어](README/README-ko.md) | [Español](README/README-es.md) | [Français](README/README-fr.md) | [Deutsch](README/README-de.md)

# AtomVoice

<p align="center"><img src="README/AppIcon-1024.png" width="128"></p>

<h3 align="center">Press, speak.</h3>
<p align="center">Lightweight, privacy-first voice dictation that types into any Mac app, with no time limit.</p>



---

<p align="center">
  <a href="#requirements"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=for-the-badge"></a>
  <a href="https://www.swift.org"><img alt="Swift 5.9+" src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=for-the-badge&logo=swift&logoColor=white"></a>
  <a href="https://github.com/BlackSquarre/AtomVoice/releases"><img alt="Download Releases" src="https://img.shields.io/badge/Download-Releases-2EA44F?style=for-the-badge"></a>
  <a href="LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache--2.0-blue?style=for-the-badge"></a>
</p>

### 🔒 Privacy First
AtomVoice makes cloud use explicit. Sherpa-ONNX is fully offline, Apple Speech can be forced on-device when the current language supports it, and Doubao Cloud ASR / LLM Refinement are opt-in. AtomVoice itself does not run a server, keep recordings, or store transcript history.

### ⚡ Lightweight
The app bundle is under 3 MB and runs no background daemons. Sherpa-ONNX local recognition can use the CoreML backend to reduce CPU load and power usage; Sherpa runtime, ASR models, and punctuation models are downloaded on demand, and large local models can be released after idle time or critical memory pressure.

### ⌨️ Input Method Friendly
AtomVoice does not take over your system input method or change how you type. Keep your existing Chinese/English IMEs, shortcuts, and preferences; type when you want, speak when you want. For long sentences, quick additions, or cross-app writing, voice input can pick up wherever typing leaves off.

---

## Features

### Recording & input
- **Hold-to-talk or tap-to-talk** — your choice, with optional ASR-text-driven silence auto-stop to reduce false cutoffs for quiet speech or noisy rooms
- **Customizable trigger key** — pick whichever modifier fits your keyboard
- **In-recording shortcuts** — cancel the take, inject immediately and skip LLM polish, or end with a punctuation in one keypress
- **Headphone Voice Control (Beta)** — use the headphone play/pause button for voice input; verified with USB headset / DAC controls and 3.5 mm headset buttons: single press follows your input mode, long press talks, double press sends Return
- **Auto-cancel on app switch** (hold mode only)

### Recognition engines
- **Apple Speech Recognition** — system engine with streaming, optional on-device mode, and **segmented rolling** that breaks the 1-minute SFSpeechRecognizer limit
- **Sherpa-ONNX** — fully offline local engine with language-specific model presets, CPU/CoreML backends, on-demand runtime/model/punctuation downloads, auto-unload, and third-party model import
- **Doubao Cloud ASR** — optional Volcengine streaming recognition with API Key stored in Keychain, ITN, smart punctuation, text smoothing, optional final-pass recognition, and Apple Speech fallback on cloud failures
- **8 app and recognition languages** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch; Sherpa also supports imported third-party models for languages without built-in presets

### Text output
- **Apple Live Insertion** — completed sentences are injected during recording, no need to wait for release
- **Smart punctuation** — local heuristic punctuator (per-language); skipped automatically when the cursor is already followed by punctuation
- **CJK IME compatible** — temporarily switches to ASCII layout before paste, restores after
- **LLM Refinement (Beta)** — text-only post-processing with OpenAI-compatible **and Anthropic** APIs, streaming preview, 10 preset providers + fully editable custom list, multilingual default system prompt or your own

### UI & animation
- **5-band FFT spectrum waveform** tuned for the human voice (100–4200 Hz), driven by Accelerate
- **Three animation styles** — Dynamic Island (Spotlight-style spring + Gaussian blur), Minimal, None — three speeds, ProMotion 120 Hz aware
- **Liquid Glass** on macOS 26, Visual Effect blur on macOS 14/15
- **8 UI languages**, auto-detected from system

### System integration
- **First-run setup** guides permissions, input mode, and recognition-engine choice
- **Auto update** from GitHub Releases with SHA256 and code-signature verification (optional Beta channel)
- **Launch at login** (SMAppService)
- **Audio input device picker** — choose any system microphone
- **Audio route resilience** — recording can recover when headphones, AirPods, or input devices change mid-session; audio is resampled per recognition engine
- **Lower system volume while recording** (optional)
- **Single-instance protection** — old instance is terminated automatically on launch, reducing multiple app copies competing for headphone button events

## Requirements

- **macOS 14 Sonoma or later**
- Permissions: **Accessibility**, **Microphone**, **Speech Recognition**

## Installation

**From Release (recommended)**

Download from [Releases](https://github.com/BlackSquarre/AtomVoice/releases), unzip, drag to Applications. Three architectures are published per release: Universal / Apple Silicon / Intel.

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**Build from source**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make dev
open dist/Test/AtomVoice.app
```

For architecture and localization coverage checks, run:

```bash
make test
make lint-loc
```

`make lint-loc` scans `loc("key")` usage against the 8 localization directories to catch missing UI translations.

The Makefile bundles and signs the app with the Apple Development identity configured in `Makefile`; change that identity if you build on another Mac.

## ⚠️ Gatekeeper Warning

Not notarized. On first open:

1. Right-click `AtomVoice.app` → **Open** → click **Open**
2. Or go to **System Settings → Privacy & Security** → **Open Anyway**
3. Or run: `xattr -cr /Applications/AtomVoice.app`

## Usage

| Action | Result |
|--------|--------|
| Hold trigger key | Start recording (hold mode) |
| Release trigger key | Stop and inject text |
| Tap trigger key | Start / stop recording (tap mode) |
| Click capsule while recording | Stop and inject text |
| `ESC` while recording | Cancel, no text injected |
| `Space` / `Backspace` while recording | Inject immediately, skip LLM |
| Type punctuation while recording | Inject + append that punctuation |
| Headphone play/pause button (optional, Beta) | Single press follows input mode, long press records, double press sends Return |
| Menu bar icon | Switch engine / language / input mode / animation / ASR settings / LLM |

## Recognition Engine Setup

- **Apple Speech** works out of the box. Enable on-device recognition when the selected language supports it.
- **Sherpa-ONNX** can be configured in **Recognition Engine Settings → Sherpa Local**. Choose language, model preset, CPU/CoreML provider, auto-unload delay, or import a third-party model package.
- **Doubao Cloud ASR** can be configured in **Recognition Engine Settings → Doubao Cloud ASR**. Enter your Volcengine API Key, choose the model version, and keep or edit the WebSocket endpoint. The first switch to Doubao asks for cloud-audio confirmation.

## LLM Refinement (Beta) Setup

Menu bar → **LLM Refinement (Beta)** → **Settings** — pick a provider preset or add your own, enter API key and model name. Streaming output is previewed live in the capsule.

Built-in presets: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Custom.

The default system prompt is tuned for dictation polish (fix homophones, mis-transcribed product/API names, fillers, punctuation) and switches automatically by recognition language. You can override it with your own prompt. LLM Refinement sends recognized text, not audio, to the provider you select.

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.

Third-party notices (Sherpa-ONNX / ONNX Runtime) are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Privacy policy: [English](README/privacy/PRIVACY-en.md) / [简体中文](README/privacy/PRIVACY-zh-Hans.md).
