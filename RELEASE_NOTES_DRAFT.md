## What's New
- **Sherpa Local Recognition:** Added a fully offline recognition engine with on-demand downloads for the runtime, ASR model, and punctuation model, plus direct engine switching from the menu bar.
- **Doubao Cloud ASR:** Added low-latency Chinese streaming recognition with punctuation, ITN, disfluency cleanup, and optional second-pass text polish.
- **Apple Speech Enhancements:** Added Apple Force Offline and Apple Live Insert, allowing supported languages to stay local and completed sentence segments to be inserted during recording.
- **Sherpa Model Management:** Expanded Sherpa model handling with per-language presets, downloaded vs. available grouping, onboarding model selection, model deletion, and third-party model import.
- **Setup Guide:** Added a first-launch setup flow covering permissions, trigger key, input mode, and recognition engine selection. The guide can also be re-run later from the menu bar.

## Improvements
- **Setup & Settings:** Refined the setup and settings flow. Recognition Engine Settings now opens on the active engine tab, Sherpa selection during onboarding immediately asks for language and model, and Doubao settings follow the global language, punctuation, and stop-delay controls.
- **Sherpa Startup:** Smoothed first-run behavior so recording can begin immediately while an uncached local model finishes loading in the background.
- **Sherpa Downloads:** Improved download resilience with GitHub reachability probing, mirror fallback, per-preset validation, and unified handling for built-in and imported models.
- **Recording Audio Balance:** Added an option to lower system volume while recording, reducing interference from system audio playback.
- **Localization & Documentation:** Expanded language coverage across the app, README, and privacy policy to English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, and Deutsch.
- **Distribution:** Added Homebrew installation support and improved release automation, including the optional Beta update channel in-app.
- **Licensing:** Updated the project license to Apache 2.0 and bundled third-party notices for Sherpa-ONNX and ONNX Runtime.

## Bug Fixes
- **Doubao Fallback:** Doubao Cloud ASR now falls back to Apple Speech when the network is unavailable or a streaming session fails, preserving partial text and buffered audio whenever possible.
- **Short-Clip Handling:** Silent or very short Doubao recordings no longer surface harmless socket-close errors as user-visible failures.
- **Sherpa Compatibility:** Sherpa model loading no longer assumes fixed encoder, decoder, joiner, and tokens filenames, improving compatibility with a wider range of official and third-party model packages.
- **Preset Recovery:** If the saved Sherpa preset points to a missing or undownloaded model, AtomVoice now repairs the selection or prompts for download instead of failing later at load time.
- **Update State Handling:** Repeated clicks during update checking or downloading no longer stack duplicate prompts.
- **Trigger Key Stability:** Trigger key handling is more reliable across more modifier-key choices, and AtomVoice now cleans up older running instances automatically to avoid duplicate menu bar items.

---

## 新功能
- **Sherpa 本地识别：** 新增完全离线识别引擎，支持按需下载 Sherpa 运行库、ASR 模型和标点模型，并可直接在菜单栏切换识别引擎。
- **豆包云识别：** 新增 Doubao Cloud ASR，提供面向中文的低延迟流式识别，并支持标点、ITN、语气词清理和可选的二次文本优化。
- **Apple Speech 增强：** 新增 Apple Force Offline 和 Apple Live Insert，让支持的语言尽量走本地识别，并可在录音过程中分段直接上屏。
- **Sherpa 模型管理：** 扩展了按识别语言切换预设、区分“已下载 / 可下载”模型、首次引导选模型、删除模型，以及导入第三方模型包等能力。
- **首次启动向导：** 新增首次启动向导，覆盖权限授权、触发键选择、输入模式和识别引擎选择，也可以之后从菜单栏重新打开。

## 优化
- **设置与引导：** 设置与引导流程进一步完善。识别引擎设置窗口会默认打开到当前引擎；首次引导里选择 Sherpa 会立刻进入语言和模型选择；豆包设置会直接跟随全局语言、自动标点和停止延迟。
- **Sherpa 启动体验：** 首次使用 Sherpa 时，即使本地模型尚未缓存，也可以先开始录音，再在后台完成模型加载。
- **Sherpa 下载链路：** 下载流程更稳健，会先探测 GitHub 可达性，必要时尝试镜像候选地址；同时会按当前预设校验解压结果，并把内置模型和导入模型统一纳入同一套管理流程。
- **录音音量控制：** 新增录音时自动降低系统音量选项，减少系统播放声音对口述的干扰。
- **本地化与文档：** 应用界面、README 和隐私政策的语言覆盖进一步扩展到 English、简体中文、繁體中文、日本語、한국어、Español、Français、Deutsch。
- **分发与安装：** 新增 Homebrew 安装支持，并完善了发布自动化；应用内也加入了可选的 Beta 更新通道。
- **许可证：** 项目许可证已更新为 Apache 2.0，并补充打包了 Sherpa-ONNX / ONNX Runtime 的第三方许可证说明。

## Bug 修复
- **豆包失败回退：** 豆包云识别在断网或流式连接失败时，现在会自动回退到 Apple Speech，并尽量保留已经识别出的部分文本和缓存音频。
- **短录音处理：** 豆包在静音或极短录音场景下，不再把无害的 socket 关闭报错显示成识别失败。
- **Sherpa 模型兼容性：** Sherpa 模型加载不再假定固定的 encoder / decoder / joiner / tokens 文件名，对更多官方和第三方模型包的兼容性更好。
- **预设自动修复：** 如果已保存的 Sherpa 预设指向缺失或未下载的模型，AtomVoice 现在会自动修正选择，或提示立即下载，而不是等到真正识别时才失败。
- **更新状态处理：** 自动更新检查或下载过程中，重复点击不再堆叠弹出重复提示。
- **触发键稳定性：** 触发键处理在更多修饰键选项下更稳定了，AtomVoice 启动时也会自动清理旧实例，避免出现重复菜单栏图标。
