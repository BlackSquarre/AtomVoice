# AtomVoice 解耦开发文档

创建日期：2026-05-14  
工作分支：`decouple/architecture-foundation`

## 目标

在不改变用户可见行为的前提下，逐步降低全局依赖和核心控制器复杂度，让录音、识别、权限、窗口呈现、设置和模型生命周期拥有更清晰的边界。

本轮优先做“架构地基”类拆解：先移除低风险的全局反向依赖，再为录音和 ASR 状态机拆分建立接口。

## 当前结构概览

当前应用是 SwiftPM 多 target、AppKit 菜单栏应用：

- `AtomVoiceCore`：主体代码，路径 `Sources/AtomVoice`。
- `AtomVoice`：启动包装，路径 `Sources/AtomVoiceApp/main.swift`。
- `AtomVoiceArchitectureTests`：自定义轻量测试 runner，路径 `Tests/AtomVoiceArchitectureTests`。

主要链路为：

`FnKeyMonitor` 触发录音 -> `RecordingSessionController` 编排音频和 ASR -> `AudioEngineController` 采集并交给 `AudioRouter` 分发 -> `CapsuleWindowController` 展示状态 -> `TextOutputSink` / `TextInjector` 上屏文本。

`AppDelegate` 仍是事实上的组合根，负责创建菜单、录音会话、音频、OOBE、更新检查和 Sherpa 下载/自动卸载协调；ASR 引擎创建已迁到 `ASREngineProvider`，权限已迁到 `PermissionService`，窗口/弹窗呈现已迁到 `WindowPresenter` / `AlertPresenter`，音频采集与下游消费已通过 `AudioRouter` 分离。

## 主要耦合点

1. `AppDelegate` 仍负责较多启动与业务编排，包括菜单、录音会话接线、OOBE、更新、Sherpa 下载胶囊和自动卸载协调。
2. `RecordingSessionController` 同时承担录音状态机、ASR 路由、fallback、UI 更新、LLM、标点、输出注入和错误处理。
3. `RecordingSessionController` 已通过 `ASREngineProviding` 获取引擎，但内部仍有 Apple/Sherpa/Doubao 特殊能力分支，下一步需要能力协议继续收敛。
4. `AppSettings` 是全局静态设置仓库，跨 ASR、LLM、音频、UI、更新和 OOBE。
5. 窗口、权限、ASR provider 已完成第一轮边界抽取，后续需要避免新代码绕回 `AppDelegate` 静态 helper 或直接系统权限 API。
6. Sherpa 预设、下载、路径、镜像、ready 检查和 UI 状态混杂。
7. `AudioEngineController` 已收敛为 AVAudioEngine 生命周期、输入设备和 tap source；`AudioRouter` / `AudioAnalyzer` 已拆出分发、重采样、FFT 和静音检测，但 `RecordingSessionController` 仍直接注册各 ASR 消费者并持有音频编排细节。

## 解耦原则

1. 最小行为变化：每一步优先移动职责，不改变用户可见流程。
2. 单 owner 生命周期：音频引擎、ASR 引擎、Sherpa 模型、LLM、TextInjector 继续只有一个明确 owner。
3. 避免重复加载：尤其禁止因为抽 factory 导致 Sherpa 模型重复实例化。
4. 先抽边界再拆状态机：先降低 `AppDelegate` 和全局 UI 依赖，再动录音核心链路。
5. 设置迁移小步做：默认值、UserDefaults key、Keychain 和已有用户数据必须保持兼容。
6. 每阶段结束都要更新本文档，并至少做一次构建验证。

## 分阶段路线图

### 自动化测试基线

状态：已完成首批基线（2026-05-14）

当前机器已安装完整 Xcode toolchain（`/Applications/Xcode.app`），`XCTest` 与 Swift `Testing` 模块可用；若默认 `xcode-select` 仍指向 `/Library/Developer/CommandLineTools`，命令行里可能会表现为找不到 `xctest` / `xcodebuild`，可临时用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 指向完整 Xcode。

项目当前测试方案仍采用项目内测试可执行文件，方便在不触发系统权限弹窗、不依赖真实音频/模型的前提下跑架构回归：

- `AtomVoiceCore`：从原 App target 拆出的可测试核心 target，包含应用主体源码。
- `AtomVoice`：保留产品名，仅作为启动入口，依赖 `AtomVoiceCore`。
- `AtomVoiceArchitectureTests`：轻量测试可执行文件，不依赖系统测试框架，通过 `make test` 运行。

首批覆盖范围：

- `PermissionKind` 卡片 tag 映射。
- `PermissionService.hasRequiredPermissions` 的语音识别必需/非必需分支。
- `PermissionService.requestOrOpenSettings` 对未决定权限、已拒绝权限、Accessibility 设置跳转的分支。
- `ASREngineProvider` 对 Speech、Apple、Sherpa、Volcengine 引擎的懒加载与实例复用。
- Sherpa provider 释放路径：未加载模型时释放不触发模型加载，释放后可重新创建实例。

运行方式：

```bash
make test
```

验收标准：

- `make test` 通过。
- `make dev` 继续通过。
- 测试不弹系统权限框、不打开系统设置、不加载 Sherpa 模型。

### 阶段 1：窗口与弹窗呈现层

状态：已完成（2026-05-14）

目标：新增 `WindowPresenter` / `AlertPresenter`，把窗口激活、modal alert 和 activation policy 恢复逻辑从 `AppDelegate` 抽出。

范围：

- 新增窗口呈现协议与默认实现。
- 替换 `AppDelegate.bringToFront`、`AppDelegate.bringToFrontInCurrentSpace`、`AppDelegate.runModalAlert`、`AppDelegate.resetActivationIfNeeded` 调用。
- 保留行为一致：LSUIElement 菜单栏应用仍能在当前 Space 打开窗口，modal alert 仍恢复 accessory activation policy。

验收标准：

- `AppDelegate` 不再持有窗口/alert 呈现静态 helper。
- 设置、权限、OOBE、About、Update、Sherpa import 等窗口控制器通过新呈现层工作。
- `make dev` 通过。

### 阶段 2：权限服务

状态：已完成（2026-05-14）

目标：抽 `PermissionService`，统一麦克风、语音识别、辅助功能状态、请求和跳转系统设置逻辑。

范围：

- 替换 `AppDelegate`、`MenuBarController`、`OOBEWindowController`、`PermissionsWindowController` 中重复权限代码。
- 保持 OOBE 首次启动行为不变。

验收标准：

- 权限状态判断只有一个实现来源。
- 权限请求和系统设置跳转逻辑集中。
- `make dev` 通过。

### 阶段 3：ASR 引擎提供者与能力协议

状态：进行中（2026-05-14 完成 provider/factory 抽取）

目标：把 ASR 引擎创建、缓存和特殊能力从 `AppDelegate` / `RecordingSessionDelegate` 中移出。

范围：

- 新增 `ASREngineProvider` 或等价 factory。
- 用能力协议表达同步停止、模型加载、模型释放、标点和 cloud fallback 所需能力。
- `RecordingSessionController` 不再通过 delegate 获取具体引擎类型。

验收标准：

- `AppDelegate` 不再是 ASR 引擎工厂。
- Sherpa 仍只加载一份模型。
- Apple、Sherpa、Doubao 三种识别路径行为不变。
- `make dev` 通过。

### 阶段 4：录音会话 UI Presenter

目标：抽 `RecordingSessionPresenter`，让 session 状态机通过事件驱动胶囊 UI，而不是直接操作 `CapsuleWindowController`。

范围：

- 封装 recording、progress、error、refining、text update、dismiss 等 UI 行为。
- 保持现有胶囊动画和错误展示时序不变。

验收标准：

- `RecordingSessionController` 中直接胶囊操作显著减少。
- 录音开始、失败、停止、LLM 润色、fallback 展示行为不变。
- `make dev` 通过。

### 阶段 5：最终文本处理流水线

目标：抽 `RecognitionResultFinalizer`，集中处理 raw text 到最终上屏 action 的流程。

范围：

- 自动标点。
- LLM 润色。
- streaming replacement。
- immediate stop 标点追加。
- error fallback 和 deliver。

验收标准：

- finalization 可独立阅读和测试。
- paste 输出、streaming 输出、Apple live insertion 行为不变。
- `make dev` 通过。

### 后续阶段

- 优先抽 `RecognitionResultFinalizer`，先把 `RecordingSessionController` 里的最终文本处理、自动标点、LLM 决策、immediate punctuation、streaming replacement 和空文本决策集中成可测试纯逻辑。
- 再抽 `RecordingSessionPresenter`，把胶囊 UI 的 recording / progress / error / refining / text update / dismiss / shimmer / bands update 从 session 状态机中拿出去。
- 补齐 ASR capability protocol，减少 `RecordingSessionController` 对 Apple / Sherpa / Doubao 具体类型的认知，但只抽当前真实需要的能力。
- 拆 `AppSettings` 为 typed stores。
- 把 LLM API Key 迁移到 Keychain。
- 拆 Sherpa catalog / selection store / downloader / presenter。
- 继续收敛音频接入边界：`AudioRouter` / `AudioAnalyzer` 已拆出，后续评估是否把 `RecordingSessionController` 中各引擎的 router 注册代码收敛为小型 audio consumer adapter。
- 拆 `UpdateChecker` 的 Release client、validator、installer、UI。

## 内存与生命周期约束

1. 解耦不应引入额外 Sherpa 模型实例。
2. `AudioEngineController`、`TextInjector`、`LLMRefiner` 仍由组合根统一创建或以单一服务持有。
3. 新 presenter/service 不缓存音频 buffer、大文本或下载数据，除非原有逻辑已经需要。
4. Timer、observer、closure 必须避免强引用泄漏。
5. 窗口控制器仍按需创建，不在启动时初始化全部设置窗口。

## 风险与回滚策略

1. 阶段 1 风险主要是窗口激活和 modal alert 时序。回滚方式是恢复 `AppDelegate` 静态 helper 调用。
2. 阶段 2 风险主要是权限请求时机。回滚方式是保留 service，但逐个调用点退回原实现。
3. 阶段 3 风险主要是 ASR 生命周期和 Sherpa 模型重复加载。必须小步替换并验证三种引擎。
4. 阶段 4/5 风险主要是胶囊展示和最终上屏时序。必须保持原有异步 dispatch 和 delay 策略。

## 进度记录

### 2026-05-14

- 创建分支：`decouple/architecture-foundation`。
- 新增本文档，记录解耦目标、阶段计划、验收标准和生命周期约束。
- 完成阶段 1：新增 `Sources/AtomVoice/WindowPresenter.swift`，包含 `WindowPresenting`、`AlertPresenting`、`WindowPresenter`、`AlertPresenter`。
- 将 `AppDelegate` 中的窗口激活、modal alert、activation policy 恢复职责迁移到呈现层。
- 替换设置、权限、OOBE、About、Update、Sherpa import、菜单等调用点，不再调用 `AppDelegate.bringToFront`、`AppDelegate.bringToFrontInCurrentSpace`、`AppDelegate.runModalAlert`、`AppDelegate.resetActivationIfNeeded`。
- 验证：`make dev` 通过，产物为 `dist/Test/AtomVoice.app`。
- 下一步：进入阶段 2，抽取 `PermissionService`，统一权限状态、请求和系统设置跳转逻辑。
- 完成阶段 2：新增 `Sources/AtomVoice/PermissionService.swift`，集中 `PermissionStatus`、`PermissionKind`、权限状态读取、权限请求、系统设置跳转和启动权限请求逻辑。
- `PermissionsWindowController` 与 `OOBEWindowController` 不再直接调用 `AVCaptureDevice`、`SFSpeechRecognizer`、`AXIsProcessTrusted` 或硬编码隐私设置 URL。
- `MenuBarController` 的权限汇总判断和 Accessibility 警告跳转改为通过 `PermissionService`。
- `AppDelegate.requestPermissions()` 改为委托 `PermissionService.requestStartupPermissions()`。
- 清理 OOBE、权限窗口、菜单、AppDelegate 中不再需要的权限 framework import。
- 验证：`make dev` 通过，产物为 `dist/Test/AtomVoice.app`。
- 下一步：进入阶段 3，抽取 ASR 引擎 provider，并保留 Sherpa 模型单 owner 生命周期。
- 阶段 3 子步骤完成：新增 `Sources/AtomVoice/ASREngineProvider.swift`，集中 Apple、Sherpa、Volcengine、Speech fallback 相关实例的懒加载与缓存。
- `AppDelegate` 不再持有 `speechRecognizer`、`sherpaRecognizer`、`volcengineProvider`、`cloudRecognizer`、`appleASREngine`、`sherpaASREngine`、`volcengineASREngine`，也不再包含 `ensure*` 引擎工厂方法。
- `RecordingSessionController` 改为通过 `ASREngineProviding` 获取识别引擎，`RecordingSessionDelegate` 不再暴露具体引擎获取方法，仅保留 Sherpa 下载和录音结束通知。
- Sherpa 模型释放逻辑由 `ASREngineProvider.releaseSherpaEngine()` 统一处理，仍保持单实例懒加载与按需释放。
- 验证：`make dev` 通过，产物为 `dist/Test/AtomVoice.app`。
- 下一步：继续阶段 3，评估是否引入更细的能力协议，进一步减少 `RecordingSessionController` 对具体引擎类型的认知。
- 自动化测试基线完成：将原 `AtomVoice` 源码拆为 `AtomVoiceCore` target，新增启动包装 target `Sources/AtomVoiceApp/main.swift`，并新增 `Tests/AtomVoiceArchitectureTests/main.swift` 自定义测试 runner。
- 新增 `make test`，执行 `swift run -Xswiftc -enable-testing AtomVoiceArchitectureTests`。
- 为 `PermissionService` 增加 `PermissionAccessing` 抽象，测试使用 fake access，避免真实权限弹窗和系统设置跳转。
- 验证：`make test` 通过 10 条架构测试；`make dev` 通过，产物为 `dist/Test/AtomVoice.app`。
- 菜单控制器拆分子步骤完成：新增 `HelpAlertPresenter`、`MenuWindowRouter`、`PrivacyPolicyURLProvider`。
- `MenuBarController` 不再内联 Engine/LLM How-To 富文本弹窗构造，不再直接持有 Settings、Doubao Settings、ASR Settings、About、Permissions 窗口控制器，也不再内联隐私政策语言映射。
- `MenuBarController.swift` 从约 1043 行降至约 790 行；菜单结构和 selector action 机制保持不变。
- 音频管线优化完成：新增 `Sources/AtomVoice/AudioRouter.swift`，由 tap 统一把设备原生 `AVAudioPCMBuffer` 分发给按目标 format 注册的消费者。
- `AudioRouter` 支持 nil-format 原生透传与 `.voice16k` 目标格式，按"输入 format 指纹 + 目标 format"缓存 `AVAudioConverter`，同一目标 format 的多个消费者每帧只重采样一次；输入设备/engine 重建时通过 `router.invalidate()` 丢弃缓存。
- 新增 `Sources/AtomVoice/AudioAnalyzer.swift`，把静音检测和 5 段 FFT 可视化从 `AudioEngineController` 中拆出，固定订阅 router 的 16kHz mono 通道，避免频段和阈值随设备采样率漂移。
- `AudioEngineController` 不再持有 `bandsHandler`、`recognitionRequest`、通用 `audioBufferHandler`、FFT 状态或静音检测逻辑；tap 的职责收敛为 `router.receive(buffer)`，仍负责 AVAudioEngine 生命周期、输入设备、路由变化和 engine 重建。
- `RecordingSessionController` 各启动路径改为按需注册 router 消费者：Apple Speech 使用 nil-format 原生透传，Sherpa / 豆包 / `AudioAnalyzer` 使用 `.voice16k`；录音结束时通过 `activeRouterConsumerID` 注销本次 ASR 消费者。
- 记录音频管线设计到 `localdoc/audio-pipeline.md`，包括 mid-recording 设备切换、converter cache 失效、Apple Live Fallback `switchRequest` 和各引擎目标 format 约束。

### 2026-05-17

- 复核当前解耦收益：外围边界已经基本成型，`AppDelegate` 更接近组合根，`AudioEngineController` 已收敛为 AVAudioEngine 生命周期 / 输入设备 / tap source，`AudioRouter` 与 `AudioAnalyzer` 的边界合理且收益明确。
- 确认下一阶段不继续过度拆 `AudioRouter`；音频侧如需再动，只评估是否把 `RecordingSessionController` 中各引擎的 router 注册代码收敛为轻量 adapter。
- 确认核心复杂度仍集中在 `RecordingSessionController`：录音状态机、ASR 路由、Doubao fallback、Apple live insertion、Sherpa preload、胶囊 UI、LLM、自动标点、streaming output 和最终注入仍在同一控制器里。
- 调整后续优先级：先抽 `RecognitionResultFinalizer`，再抽 `RecordingSessionPresenter`，最后补 ASR capability protocol；`AppSettings` typed stores、Sherpa catalog/downloader、UpdateChecker 拆分暂缓。
- 确认完整 Xcode toolchain 位于 `/Applications/Xcode.app`，`XCTest` 与 Swift `Testing` 模块可用；但当前项目测试入口仍为 `make test` 的自定义 `AtomVoiceArchitectureTests` runner，不改成 `swift test`。
- 给后续 agent 的执行边界：第一阶段只做 `RecognitionResultFinalizer`，保持用户可见行为不变，不触发权限弹窗、系统设置、真实音频、云 ASR 或 Sherpa 模型加载；完成后更新本文档并跑 `make test`。
