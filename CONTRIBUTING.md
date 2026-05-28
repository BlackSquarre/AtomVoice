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
