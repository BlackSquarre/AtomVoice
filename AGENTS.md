# AGENTS.md

## 项目形态
- `AtomVoice` 是 macOS 14+ 菜单栏语音输入 App，纯 Swift + AppKit。
- 当前 SwiftPM 拆分：`AtomVoiceCore` 在 `Sources/AtomVoice` 放主体代码；`AtomVoice` 只是 `Sources/AtomVoiceApp/main.swift` 启动包装。
- 主链路仍从 `AppDelegate` 接线：触发键 -> `RecordingSessionController` -> ASR 引擎 -> `TextOutputSink` / `TextInjector`。
- 正在做架构解耦；每完成一个阶段都要更新 `localdoc/decoupling-architecture-plan.md`。
- 旧的 `CLAUDE.md` / `OPENCODE.md` / `CODEX.md` / `GEMINI.md` 有些架构描述可能滞后；命令和 target 以 `Package.swift`、`Makefile`、本文件为准。

## 常用命令
- `make dev`：release 编译并带 `DEBUG_BUILD`，打包签名到 `dist/Test/AtomVoice.app`，用于手动测试。
- `make run`：编译 `.build/release/AtomVoice.app` 并打开。
- `make test`：运行自定义测试可执行文件 `AtomVoiceArchitectureTests`；不要改成 `swift test`，当前工具链缺 `XCTest` / Swift `Testing` 模块。
- `make release`：构建 AppleSilicon / Intel / Universal 三个 zip；只能在用户明确要求发版时运行。
- `make sherpa-memory`：Sherpa 内存 benchmark，依赖本机模型/运行库状态，可能较重，不要顺手运行。

## 构建产物与工作树
- `dist/Test/AtomVoice.app` 是 `make dev` 产物；`dist/AtomVoice-*.zip` 是发布产物，不是源码。
- 仓库经常因为测试或发版产物处于 dirty 状态；不要清理、回滚或删除无关改动/产物，除非用户明确要求。
- `make clean` 会删除 `.build` 和整个 `dist`，可能清掉用户需要的 release 包，谨慎使用。
- Makefile 使用本机 Apple Development 证书签名；别的机器上 `make dev` 可能因证书不存在而失败。

## 测试约束
- `Tests/AtomVoiceArchitectureTests` 是项目内轻量测试 runner，不依赖系统测试框架。
- 自动化测试不得触发真实权限弹窗、打开系统设置、采集音频、访问云端 ASR、下载或加载 Sherpa 模型。
- 权限测试走 `PermissionService` 的 `PermissionAccessing` fake 边界。
- Sherpa 相关测试只能验证 provider/路径/状态等轻逻辑；需要真实模型的验证放到手动测试或显式 benchmark。

## 编码约定
- 代码注释使用中文。
- 新增用户可见字符串必须走 `loc()`，并同步更新 8 个本地化目录：`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`es`、`fr`、`de`。
- Debug-only UI 或功能必须包在 `#if DEBUG_BUILD`；release 构建不传 `-DDEBUG_BUILD`。
- 不要硬编码 UI 文案；缺本地化会回退显示 key。
- Commit 标题、tag、release 相关提交默认用英文。

## localdoc 文档命名约定
- 时间锚定的设计 / 排查 / 重构记录：`YYYY-MM-DD-<kebab-case-topic>.md`（如 `2026-05-16-memory-optimization.md`）。
- 长青参考资料（与日期无关、长期维护）：`<topic>.md`（如 `volcengine-asr-hld.md`、`sherpa-model-download.md`）。
- 特例：`RELEASE_NOTES_DRAFT.md` 保持全大写。

## 解耦边界
- 窗口/弹窗激活集中在 `WindowPresenter` / `AlertPresenter`；不要新增 `AppDelegate` 静态呈现 helper。
- 权限逻辑集中在 `PermissionService`；不要在窗口或菜单里直接散落 `AVCaptureDevice`、`SFSpeechRecognizer.authorizationStatus()`、`AXIsProcessTrusted()`。
- ASR 引擎创建和生命周期集中在 `ASREngineProvider`；不要把 Apple/Sherpa/Doubao 引擎缓存搬回 `AppDelegate`。
- 避免复制重型 runtime owner：Sherpa 模型、ASR 引擎、`AudioEngineController`、`TextInjector`、`LLMRefiner` 都应保持单 owner 或懒加载。

## ASR / Sherpa / 凭据注意事项
- 三个 ASR 引擎：Apple Speech、本地 Sherpa-ONNX、Doubao/Volcengine WebSocket。
- Doubao API Key 走 `KeychainStore`；不要把新的长期密钥写入 `UserDefaults`。
- Sherpa 运行库和模型在 `~/Library/Application Support/AtomVoice/SherpaOnnx/`，通过 C shim 运行时 `dlopen`，不要改成编译期硬链接。
- Sherpa 包含 Runtime、当前 ASR 模型、标点模型三类组件；模型 ready 判断以实际文件/manifest 为准，不要恢复旧的 `sherpaModelsReady` 持久化标记。
- Sherpa 模型和标点模型内存占用高，保持按需加载和可释放策略。

## 发布规则
- 只有用户明确说“发版 / release”时才执行发布流程。
- `make release` 前同步更新 `Makefile` 的 `VERSION` 和 `Sources/AtomVoice/Info.plist` 的 `CFBundleShortVersionString`。
- 发布前更新 `localdoc/RELEASE_NOTES_DRAFT.md`：英文在前、中文在后，固定 `What's New / Improvements / Bug Fixes` 与 `新功能 / 优化 / Bug 修复`。
- 正式版 release notes 以“上一个正式版之后”的全部用户可见变化为基线，不能只写最后一个 Beta。
- `make release` 完成后停下来，等待用户确认再提交、打 tag、push 或创建 GitHub Release。
