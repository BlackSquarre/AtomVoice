# AGENTS.md

## 项目入口

- `AtomVoice` 是 macOS 14+ 菜单栏语音输入 App，纯 Swift + AppKit。
- SwiftPM 拆分：`AtomVoiceCore` 在 `Sources/AtomVoice`，`AtomVoice` 在 `Sources/AtomVoiceApp/main.swift` 只做启动包装。
- 主链路从 `AppDelegate` 接线：触发键 -> `RecordingSessionController` -> ASR 引擎 -> `TextOutputSink` / `TextInjector`。
- 已完成的架构、功能和排查记录放在 `localdoc/`；不要把这些内容重复搬回本文件。

## 常用命令

```bash
make dev            # release 编译 + DEBUG_BUILD，打包签名到 dist/Test/AtomVoice.app
make run            # 编译 .build/release/AtomVoice.app 并打开
make test           # 运行自定义 AtomVoiceArchitectureTests；不要改成 swift test
make release        # 仅在用户明确要求发版时运行
make sherpa-memory  # Sherpa 内存 benchmark，较重，除非明确要求不要运行
```

- `make clean` 会删除 `.build` 和整个 `dist`，可能清掉用户需要的 release 包，谨慎使用。
- Makefile 使用本机 Apple Development 证书签名；别的机器上 `make dev` 可能因证书不存在而失败。
- 当前机器已安装完整 Xcode toolchain：`/Applications/Xcode.app`。如果默认 `xcode-select` 指向 `/Library/Developer/CommandLineTools` 导致找不到 `xctest` / `xcodebuild`，可临时使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- `XCTest` 与 Swift `Testing` 模块可用，但当前项目测试入口仍是自定义 `AtomVoiceArchitectureTests`；不要因为模块可用就把 `make test` 改成 `swift test`。

## 工作树约束

- `dist/Test/AtomVoice.app` 是 `make dev` 产物；`dist/AtomVoice-*.zip` 是发布产物，不是源码。
- 仓库经常因为测试或发版产物处于 dirty 状态；不要清理、回滚或删除无关改动/产物，除非用户明确要求。
- 可能遇到用户或其他 agent 的未提交改动；只处理当前任务相关内容，不覆盖、不回滚无关改动。

## 代码与测试规则

- 代码注释使用中文。
- 新增用户可见字符串必须走 `loc()`，并同步更新 8 个本地化目录：`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`es`、`fr`、`de`。
- 不要硬编码 UI 文案；缺本地化会回退显示 key。
- Debug-only UI 或功能必须包在 `#if DEBUG_BUILD`；release 构建不传 `-DDEBUG_BUILD`。
- `Tests/AtomVoiceArchitectureTests` 是轻量测试 runner，不依赖系统测试框架。
- 自动化测试不得触发真实权限弹窗、打开系统设置、采集音频、访问云端 ASR、下载或加载 Sherpa 模型。
- Commit 标题、tag、release 相关提交默认用英文。

## 解耦与安全边界

- 正在做架构解耦；每完成一个阶段都要更新 `localdoc/decoupling-architecture-plan.md`。
- 当前已完成窗口/弹窗、权限、ASR provider、菜单窗口路由、AudioRouter / AudioAnalyzer 等外围解耦；下一阶段优先级是 `RecognitionResultFinalizer` -> `RecordingSessionPresenter` -> ASR capability protocol。
- `AudioRouter` / `AudioAnalyzer` 边界当前合理，不要继续过度抽象；如要动音频接入，先读 `localdoc/audio-pipeline.md`。
- 窗口/弹窗激活集中在 `WindowPresenter` / `AlertPresenter`；不要新增 `AppDelegate` 静态呈现 helper。
- 权限逻辑集中在 `PermissionService`；不要在窗口或菜单里直接散落 `AVCaptureDevice`、`SFSpeechRecognizer.authorizationStatus()`、`AXIsProcessTrusted()`。
- ASR 引擎创建和生命周期集中在 `ASREngineProvider`；不要把 Apple/Sherpa/Doubao 引擎缓存搬回 `AppDelegate`。
- Doubao API Key 走 `KeychainStore`；不要把新的长期密钥写入 `UserDefaults`。
- Sherpa 运行库和模型通过 C shim 运行时 `dlopen`；不要改成编译期硬链接。
- 避免复制重型 runtime owner：Sherpa 模型、ASR 引擎、`AudioEngineController`、`TextInjector`、`LLMRefiner` 都应保持单 owner 或懒加载。

## localdoc 索引

- 架构解耦计划：`localdoc/decoupling-architecture-plan.md`
- 音频管线：`localdoc/audio-pipeline.md`
- OOBE 首次启动引导：`localdoc/oobe-window.md`
- ASR 引擎注册与生命周期：`localdoc/asr-engine-registry.md`
- Sherpa 模型下载：`localdoc/sherpa-model-download.md`
- 豆包 ASR：`localdoc/volcengine-asr-hld.md` / `localdoc/volcengine-asr-prd.md`
- 发版草稿：`localdoc/RELEASE_NOTES_DRAFT.md`

## localdoc 命名

- 时间锚定的设计 / 排查 / 重构记录：`YYYY-MM-DD-<kebab-case-topic>.md`。
- 长青参考资料：`<topic>.md`。
- 特例：`RELEASE_NOTES_DRAFT.md` 保持全大写。

## 发版规则

- 只有用户明确说“发版 / release”时才执行发布流程。
- `make release` 前同步更新 `Makefile` 的 `VERSION` 和 `Sources/AtomVoice/Info.plist` 的 `CFBundleShortVersionString`。
- 发布前更新 `localdoc/RELEASE_NOTES_DRAFT.md`：英文在前、中文在后，固定 `What's New / Improvements / Bug Fixes` 与 `新功能 / 优化 / Bug 修复`。
- 正式版 release notes 以“上一个正式版之后”的全部用户可见变化为基线，不能只写最后一个 Beta。
- `make release` 完成后停下来，等待用户确认再提交、打 tag、push 或创建 GitHub Release。
