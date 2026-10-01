# AtomVoice Contribution Guide

## About the project

AtomVoice is a macOS 14+ menu bar voice-input app built with pure Swift and AppKit. It is designed to be offline-first, privacy-controlled, and lightweight.

Its main capabilities include:

- Hold a shortcut key to speak and inject the recognized text into any editing control.
- Choose among Apple Speech, local Sherpa-ONNX, and Doubao Cloud ASR.
- Optionally refine recognized text with OpenAI-, Anthropic-, or compatible LLM endpoints.
- Use the interface in eight languages: Simplified Chinese, Traditional Chinese, English, Japanese, Korean, Spanish, French, and German.

The source is fully open source. Contributions of all kinds are welcome.

## Current project status

AtomVoice is currently maintained primarily by one developer. The architecture has recently gone through a systematic decoupling pass:

- Recording state uses a reducer and a single dispatch entry point.
- ASR engines share the `RecognitionSession` lifecycle and remain pluggable.
- Capsule UI animation strategies are separated from view state.
- Settings use typed stores with injectable backends for testing.
- The project has 200+ lightweight architecture tests that run in CI.

The project is still evolving:

- Several heavy components intentionally have a single owner, including `AudioEngineController`, `TextInjector`, `LLMRefiner`, and Sherpa models.
- Automated tests cover pure logic and state transitions; UI and system integrations still need manual verification.
- Some behavior depends on the macOS version and on specific hardware such as USB DACs, AirPods, and wired headsets.
- The English documentation is still being expanded.

If you are comfortable contributing while the project continues to mature, you are welcome to participate. If you need an industrial-grade framework, experiment in your own fork before opening a PR.

## Quick start

### Build and run

```bash
# Clone
git clone https://github.com/<your-fork>/AtomVoice.git
cd AtomVoice

# Build, sign, and create dist/Test/AtomVoice.app
make dev

# Build and run in release mode
make run

# Run the architecture tests
make test
```

### Common first-run issues

- **Signing fails:** `make dev` uses the Apple Development identity configured for this machine. If you do not have a signing identity, use `swift build -c release` to verify compilation; an unsigned app cannot reliably request recording or Accessibility access on macOS.
- **`make test` fails:** Check `swift --version` and confirm Swift 5.9 or newer. The test entry point is the custom `AtomVoiceArchitectureTests` runner, not XCTest.
- **Sherpa models do not download:** The first launch guides you through the download. To test without network access, select Apple Speech.

## Project structure

```text
Sources/AtomVoice/
├── App/              # AppDelegate composition root
├── ASR/              # ASR engines and RecognitionSession lifecycle
├── Audio/            # AVAudioEngine, AudioRouter, AudioAnalyzer, VolumeController
├── Input/            # FnKeyMonitor, HeadphoneMonitor, trigger keys
├── Menu/             # Menu bar controllers
├── Models/           # Data models and localization support
├── Permissions/      # PermissionService
├── Recording/        # RecordingSessionController and state machine
├── Settings/         # AppSettings and typed stores
├── Text/             # TextInjector, TextOutputSink, LLMRefiner, finalizer
├── Update/           # UpdateChecker
└── Windows/          # OOBE, settings, about, capsule, and permission windows
```

The main path is:

```text
Trigger key down
  → RecordingSessionController.dispatch(.triggerPressed)
  → RecordingStateMachine.reduce → side effects
  → RecordingSideEffectExecutor
  → RecognitionSession.start
  → ASR partial/final callbacks
  → RecognitionResultFinalizer
  → TextOutputSink.deliver / TextInjector.inject
```

## Ways to contribute

### Especially welcome

1. **Improve translations:** Fix missing or unnatural text in any of the eight localization directories. Run `make lint-loc` to check coverage.
2. **Add an ASR engine:** Implement `RecognitionSession` and register the engine in `ASREngineProvider.recognitionSession(for:audioEngine:)`. Discuss the engine choice in an issue first.
3. **Fix device compatibility:** Reports and patches for USB DACs, AirPods, and wired headsets are useful. The archived headphone debugging notes contain prior examples.
4. **Expand Sherpa presets:** Add models to the Sherpa downloader catalog when they meet the project constraints, including macOS arm64 support and an available quantized build.

### Discuss first in an issue

5. **Add an LLM provider:** The current implementation supports OpenAI, Anthropic, and compatible endpoints. Explain the API compatibility before adding another provider.
6. **Add a trigger-key mode:** New modes affect `FnKeyMonitor` and the recording state machine, so align on the design first.
7. **Support an older macOS version:** The minimum is currently macOS 14. Supporting macOS 13 would require resolving API differences and should be discussed first.

### Directions currently out of scope

- iOS or iPadOS ports.
- Direct Apple Intelligence integration that requires a newer macOS-only capability.
- Paid features or subscriptions.
- A heavy SwiftUI rewrite of the existing menu bar, capsule, and settings UI.

## Contribution workflow

### Before opening a PR

1. Open an issue to discuss the direction, except for translations and small spelling fixes. Changes larger than roughly 50 lines should be aligned before implementation.
2. Run `make test` and `make lint-loc`.
3. Run `make dev` and manually verify the changed behavior. Tests cover pure logic; system and UI behavior still needs a human check.
4. Use a short English commit message that explains why the change is needed, for example: `Fix headphone double-tap sticking when fallback engaged`.

### PR description template

```markdown
## What changed
(1–3 sentences)

## Why
(1–3 sentences explaining the motivation)

## Validation
- [ ] make test
- [ ] make lint-loc
- [ ] Manually verified scenario A
- [ ] Manually verified scenario B
```

### Code style

- Write code comments in Chinese.
- Use English for commit messages and PR descriptions.
- Route every new user-visible string through `loc()` and update all eight localization directories.
- Wrap Debug-only code in `#if DEBUG_BUILD`.
- Do not add new `UserDefaults` or `Keychain` keys without preserving compatibility with released versions.
- Read the repository instructions in `AGENTS.md` and `CODEX.md` before making architectural changes.

### PRs that are not accepted

- Reducer or state-machine changes without tests.
- Opportunistic large refactors mixed with bug fixes.
- Changes to existing UserDefaults keys.
- Changes to defaults without explaining the motivation.
- New Sherpa runtime dependencies.
- Sentry, Crashlytics, or other third-party telemetry SDKs.

## Reporting bugs

Open a GitHub issue. A useful report includes:

- macOS version (`sw_vers`)
- AtomVoice version from the About window
- Trigger condition, target app, ASR engine, input device, and output device
- Expected behavior versus actual behavior
- Debug logs from `make dev`, when available
- Device name for USB or Bluetooth headset issues

Screenshots and videos are optional except for layout problems; logs are usually more useful.

## Security issues

See [`SECURITY.md`](SECURITY.md). Do not open a public issue for security problems such as API-key exposure, unexpected audio or text uploads, tamperable settings, or an update path that bypasses SHA256 and signature verification. Send a report to the maintainer's email listed on the GitHub profile with `[SECURITY]` in the subject.

## Community guidelines

Focus on the issue rather than the person, record decisions publicly, and do not harass others. The detailed standard is [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).

## Maintainer commitment

- First response to a PR within seven days, even if only to acknowledge it.
- Small fixes under 50 lines with tests are normally merged or declined within two weeks.
- Larger changes may take longer; progress will be communicated in the issue.
- PRs will not be closed without an explanation.
- Contributors will not be asked to sign a CLA that transfers their rights.
- Contributor code will not be rewritten and credited to the maintainer without discussion.

## Contact

- GitHub Issues are preferred.
- Use the maintainer's GitHub profile email for security disclosures or when email is necessary.
- Project discussion stays on GitHub so decisions remain searchable and traceable.

---

# AtomVoice 贡献指南

## 项目介绍

AtomVoice(原子微语)是一款 macOS 14+ 菜单栏语音输入 App,纯 Swift + AppKit。设计目标是**离线优先、隐私可控、低占用**。

主要能力:
- 按住快捷键说话,松手把识别结果上屏(支持任意编辑控件)
- 三套 ASR 引擎可选:Apple Speech / Sherpa-ONNX 本地 / 豆包云端
- 可选 LLM 润色(支持 OpenAI / Anthropic / DeepSeek 兼容 endpoint)
- 8 语言界面:中(简/繁)、英、日、韩、西、法、德

源码完全开源,欢迎所有形式的贡献。

---

## 项目状态(诚实版)

AtomVoice 当前由 1 人主力开发,**架构刚完成一轮系统化解耦**:

- 录音状态机:reducer + 单一 dispatch 入口
- ASR 引擎:统一 `RecognitionSession` lifecycle,三家(Apple / Sherpa / Doubao)实现可插拔
- 胶囊 UI:动画 strategy 与 view 状态隔离
- 设置:typed stores(可注入 backend,便于测试)
- 测试:160+ 条架构测试,CI 自动跑

但项目仍然**不是十全十美的开源项目**:

- 部分模块仍由单一 owner 持有(`AudioEngineController` / `TextInjector` / `LLMRefiner` / Sherpa 模型),改动需要小心
- 自动化测试覆盖纯逻辑和状态转移,**UI 与系统调用仍需手动验证**
- 部分行为依赖 macOS 版本(15+)和具体硬件(USB DAC、AirPods、有线耳机)
- 英文版文档不齐全

如果你能接受"边贡献边补齐",欢迎来。如果你期待一个工业级框架,建议先在自己的 fork 里实验一段时间再提 PR。

---

## 快速开始

### 编译运行

```bash
# 克隆
git clone https://github.com/<your-fork>/AtomVoice.git
cd AtomVoice

# 编译 + 签名(需 Apple Development 证书)→ dist/Test/AtomVoice.app
make dev

# 直接运行(release 模式)
make run

# 跑测试
make test
```

### 第一次跑遇到问题?

- **签名失败**:`make dev` 默认用本机 Apple Development 证书。如果你没有 Apple ID 或不想配证书,改用 `swift build -c release` 验证能编译即可,不能直接 run(macOS 不让未签名 app 录音、用辅助功能)。
- **`make test` 失败**:先 `swift --version` 确认 Swift 5.9+。当前测试入口是自定义 `AtomVoiceArchitectureTests` runner,不是系统 XCTest。
- **Sherpa 模型不会下载**:首次启动会引导下载。如果想本地测试不依赖网络,可直接用 Apple Speech 引擎。

---

## 项目结构速览

```
Sources/AtomVoice/
├── App/              # AppDelegate 组合根
├── ASR/              # 三家 ASR 引擎、RecognitionSession lifecycle
├── Audio/            # AVAudioEngine、AudioRouter、AudioAnalyzer、VolumeController
├── Input/            # FnKeyMonitor、HeadphoneMonitor、触发键
├── Menu/             # 菜单栏 controller
├── Models/           # 数据结构、本地化
├── Permissions/      # PermissionService
├── Recording/        # RecordingSessionController、RecordingStateMachine
├── Settings/         # AppSettings + typed stores
├── Text/             # TextInjector、TextOutputSink、LLMRefiner、Finalizer
├── Update/           # UpdateChecker
└── Windows/          # OOBE / 设置 / About / 胶囊 / 权限窗口
```

详细的目录约定见 [`localdoc/reference/source-layout.md`](localdoc/reference/source-layout.md)。

主链路简化版:
```
FnKey 按下
  → RecordingSessionController.dispatch(.triggerPressed)
  → RecordingStateMachine.reduce → SideEffect[]
  → RecordingSideEffectExecutor 执行
  → RecognitionSession.start
  → ASR partial / final 回调
  → RecognitionResultFinalizer 决定上屏方式
  → TextOutputSink.deliver / TextInjector.inject
```

---

## 我可以贡献什么

### 最欢迎的贡献

1. **翻译完善**:8 个 lproj 任何一个有 missing / 有更好表达,直接 PR。跑 `make lint-loc` 可以看到当前覆盖情况。
   - 简体中文: `Resources/zh-Hans.lproj/Localizable.strings`
   - 其他语言类似
2. **新 ASR 引擎接入**:实现 `RecognitionSession` protocol,在 `ASREngineProvider.recognitionSession(for:audioEngine:)` 注册一个新 case。推荐先在 issue 里讨论引擎选型。
3. **设备兼容性修复**:USB DAC / AirPods / 有线耳机的特殊行为反馈和补丁。`localdoc/archive/2026-05/2026-05-18-headphone-may-debug.md` 记录了 MOONDROP MAY 的踩坑过程,可作为参考。
4. **Sherpa 模型预设扩展**:`SherpaModelDownloader` 的 catalog 可以加新模型,只要符合"小于 1GB、支持 macOS arm64、量化版本可用"等约束。

### 也欢迎,但请先开 issue 讨论

5. **新 LLM provider**:`LLMRefiner` 目前支持 OpenAI / Anthropic / 兼容 endpoint。如果想加 Google / 通义等,先开 issue 说明 API 兼容性。
6. **新触发键模式**:目前支持单 Fn / 双击 / 长按。若要加新模式,涉及 `FnKeyMonitor` 和 `RecordingSessionController` 状态机,需要讨论。
7. **macOS 13 兼容性**:目前最低 14。如果想下探到 13,需要解决 `SFSpeechRecognizer` 部分 API 差异,工作量不小,先讨论。

### 暂不建议的方向

- **iOS / iPadOS 移植**:这是个 macOS 菜单栏 app,触控/键盘事件机制完全不同。
- **Apple Intelligence 直连**:目前不打算依赖 macOS 15.1+ 独占能力。
- **付费功能 / 订阅系统**:AtomVoice 是免费开源软件,不接受加入付费墙的 PR。
- **重型 UI 重写**:菜单栏 + 胶囊 + 设置窗口足够覆盖核心交互,不打算引入 SwiftUI 重写或新 onboarding 流程。

---

## 贡献流程

### 提 PR 之前

1. **开 issue 讨论方向**(除了翻译和拼写修正)。一行代码的修补可以直接 PR,但若涉及超过 50 行,先开 issue 对齐方案,免得做完发现方向不符。
2. **跑 `make test` + `make lint-loc` 通过**。CI 也会跑,但你先跑可以省一轮。
3. **跑 `make dev` 启动一次,手动验证你的改动确实工作**。测试覆盖纯逻辑,UI 行为仍需要你的眼睛。
4. **提交信息用英文**,简短描述"为什么"。例:`Fix headphone double-tap sticking when fallback engaged`。

### PR 描述模板

```markdown
## 改了什么
(1-3 句)

## 为什么这么改
(1-3 句,关键是 motivation)

## 怎么验证
- [ ] make test 通过
- [ ] make lint-loc 通过
- [ ] 手动验证场景 A
- [ ] 手动验证场景 B
```

### 代码风格

- 代码注释**用中文**(项目主开发者用中文思考)
- 提交信息、PR 描述**用英文**(便于国际协作)
- 新增用户可见字符串**必须 `loc()`**,**必须同步 8 个 lproj**(CI 的 `make lint-loc` 会拦)
- Debug-only 代码**必须包在 `#if DEBUG_BUILD`**,release 构建不传 `DEBUG_BUILD`
- **不要新增 `UserDefaults` / `Keychain` key 字符串**(会破坏已发版用户设置兼容)
- 详细规则见 [`CLAUDE.md`](CLAUDE.md)

### 不接受的 PR

- 不带测试的 reducer 状态机改动
- 顺手大重构(refactor + 修 bug 混在一个 PR)
- 改 UserDefaults key 字符串(破坏已发版用户兼容)
- 改默认值但没说明动机
- 给 Sherpa 模型加新依赖(C++ runtime / 新 framework)
- 引入 Sentry / Crashlytics / 第三方 telemetry SDK(AtomVoice 是隐私优先项目,无第三方上报)

---

## 报告 Bug

GitHub Issues 走起。**好的 bug 报告**包含:

- macOS 版本(`sw_vers`)
- AtomVoice 版本(菜单 → About)
- 触发条件(按了什么键、在什么 app、用什么 ASR 引擎、用什么输入/输出设备)
- 期望行为 vs 实际行为
- 如果有 Debug 构建(`make dev` 产物),附 `~/Library/Logs/...` 里的日志
- 如果是 USB / 蓝牙耳机问题,加上设备名

**不需要**截图、视频(除非 UI 错位类问题)。日志比截图更有用。

---

## 安全问题

详见 [`SECURITY.md`](SECURITY.md)。简要:

如果发现:
- 任意 app 可以提取 AtomVoice 存储的 API key
- AtomVoice 把语音音频或文本意外上传
- 用户设置可以被恶意 app 篡改
- 任何能绕过 SHA256 + 签名校验的更新路径

**不要**开公开 issue。发邮件到项目主开发者(邮箱见 GitHub profile),标题包含 `[SECURITY]`。会在 14 天内回复并协调披露。

---

## 社区准则

短版:**对事不对人,公开记录决策,不允许冒犯他人的言论**。

详细的就先用 [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)。

---

## 维护者承诺

- **PR 7 天内首次回复**(即使是"我看到了,这周末处理")。
- **小修补(< 50 行、有测试)2 周内合或拒**。
- **大改动可能拖更长**,会在 issue 里同步进度。
- 不会无声关 PR;关之前一定给理由。
- 不会要求贡献者签 CLA 转让权利。
- 不会未经讨论就把贡献者代码改写后归到自己名下。

---

## 致谢

感谢所有贡献者。AtomVoice 用到的开源组件见 `About` 窗口的开源致谢页(完整致谢索引待补)。

---

## 联系方式

- GitHub Issues:首选
- Email:见维护者 GitHub profile(只在安全披露 / 邮件偏好场景使用)
- 不开微信群、不开 Discord —— 项目讨论留在 GitHub 上可追溯
