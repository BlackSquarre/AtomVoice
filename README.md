**English** | [简体中文](README/README-zh-Hans.md) | [繁體中文](README/README-zh-Hant.md) | [日本語](README/README-ja.md) | [한국어](README/README-ko.md) | [Español](README/README-es.md) | [Français](README/README-fr.md) | [Deutsch](README/README-de.md)

# AtomVoice

<p align="center"><img src="README/AppIcon-1024.png" width="128"></p>

<h3 align="center">Press, speak.</h3>
<p align="center">Lightweight, privacy-first voice dictation that types into any Mac app, with no time limit.</p>



---

### 🔒 Privacy First
Speech recognition runs **on-device** by default — either via Apple Speech Recognition or the bundled Sherpa-ONNX local engine. No audio leaves your Mac unless you explicitly enable LLM Refinement.

### ⚡ Lightweight
Small app bundle, near-zero CPU when idle, no background daemons. Sherpa models are downloaded on demand and released automatically under memory pressure.

---

## Features

### Recording & input
- **Hold-to-talk or tap-to-talk** — your choice, with optional silence-based auto-stop
- **Customizable trigger key** — pick whichever modifier fits your keyboard
- **In-recording shortcuts** — cancel the take, inject immediately and skip LLM polish, or end with a punctuation in one keypress
- **Auto-cancel on app switch** (hold mode only)

### Recognition engines
- **Apple Speech Recognition** — streaming, optional on-device mode, **segmented rolling** that breaks the 1-minute SFSpeechRecognizer limit
- **Sherpa-ONNX** — fully offline local engine, models auto-download on first use; ships with a punctuation model
- **8 recognition languages** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch

### Text output
- **Apple Live Insertion** — completed sentences are injected during recording, no need to wait for release
- **Smart punctuation** — local heuristic punctuator (per-language); skipped automatically when the cursor is already followed by punctuation
- **CJK IME compatible** — temporarily switches to ASCII layout before paste, restores after
- **LLM Refinement** — OpenAI-compatible **and Anthropic** APIs with streaming preview; 10 preset providers + fully editable custom list; multilingual default system prompt or your own

### UI & animation
- **5-band FFT spectrum waveform** tuned for the human voice (100–4200 Hz), driven by Accelerate
- **Three animation styles** — Dynamic Island (Spotlight-style spring + Gaussian blur), Minimal, None — three speeds, ProMotion 120 Hz aware
- **Liquid Glass** on macOS 26, Visual Effect blur on macOS 14/15
- **8 UI languages**, auto-detected from system

### System integration
- **Auto update** from GitHub Releases with code-signature verification (optional Beta channel)
- **Launch at login** (SMAppService)
- **Audio input device picker** — choose any system microphone
- **Lower system volume while recording** (optional)
- **Single-instance protection** — old instance is terminated automatically on launch

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
| Hold trigger key | Start recording (hold mode) |
| Release trigger key | Stop and inject text |
| Tap trigger key | Start / stop recording (tap mode) |
| `ESC` while recording | Cancel, no text injected |
| `Space` / `Backspace` while recording | Inject immediately, skip LLM |
| Type punctuation while recording | Inject + append that punctuation |
| Menu bar icon | Switch engine / language / mode / animation / LLM |

## LLM Refinement Setup

Menu bar → **LLM Refinement** → **Settings** — pick a provider preset or add your own, enter API key and model name. Streaming output is previewed live in the capsule.

Built-in presets: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Custom.

The default system prompt is tuned for dictation polish (fix homophones, mis-transcribed product/API names, fillers, punctuation) and switches automatically by recognition language. You can override it with your own prompt.

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.

Third-party notices (Sherpa-ONNX / ONNX Runtime) are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
