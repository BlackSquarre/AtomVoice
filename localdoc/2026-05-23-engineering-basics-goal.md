# 工程基建与设置拆分 Goal — 2026-05-23 (round 3)

> 本文档是给下一轮 Codex 执行的完整 goal。
> 可直接以 `/goal 读 localdoc/2026-05-23-engineering-basics-goal.md 并严格按其执行` 调用。
>
> 配套阅读:
> - [2026-05-23-core-decoupling-goal.md](./2026-05-23-core-decoupling-goal.md)
> - [2026-05-23-decoupling-cleanup-goal.md](./2026-05-23-decoupling-cleanup-goal.md)
> - [decoupling-architecture-plan.md](./decoupling-architecture-plan.md)
> - [source-layout.md](./source-layout.md)

---

## 项目规则提醒

你在 `/Users/lingru/claude/VoiceInput` 工作。先读 `CLAUDE.md`,严格遵守项目规则:

- 先读后改,保持修改范围最小,尊重未提交改动,不回滚无关文件。
- 测试只用 `make test`,不要改成 `swift test`。
- 不要运行 `make release`,除非用户明确要求。
- 新增用户可见字符串必须 `loc()` 并同步 8 个 lproj。
- Debug-only 代码必须包在 `#if DEBUG_BUILD`。
- 代码注释用中文,提交信息用英文。
- 开工前先 `git status`,识别已有未提交改动,不要覆盖与本任务无关的文件或产物。

---

## 背景

前两轮 round 1 / round 2 完成了 RecordingSession / RecognitionSession / 
RecordingStateMachine reducer / CapsuleAnimationStrategy / 引擎 capability protocol / 
Apple live insertion adapter 等架构拆分。

现在架构本身的核心解耦已经到位,但工程基建仍是个人项目的水平:

- 没有 CI,Codex 改完测试可能没跑就 push
- 8 语言本地化没有 lint,漏 key 用户看到 raw key 才发现
- `.gitignore` 长期遗漏 `tmp/` / `.sisyphus/` / `.vscode/`,污染 `git status`
- 86 个测试塞在一个 `Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/main.swift` 文件里,
  加新测试要 scroll 2000+ 行找位置
- `AppSettings` 还是 static 全局门面,所有模块直读直写,无法在测试中注入

这一轮目标:不动业务逻辑,把上面五件工程基建补齐。**做完之后这个项目有
资格挂在 README 上写"欢迎贡献"**。

---

## 必读源文件

- `Makefile`
- `Package.swift`
- `.gitignore`
- `Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/main.swift`
- `Sources/AtomVoice/Settings/AppSettings.swift`(主体)
- 任何 `Sources/AtomVoice/**/*.swift` 中含 `loc(` 的文件(供任务 4 参考)
- 任何 `*.lproj/Localizable.strings`(供任务 4 参考)
- 已有 `.github/workflows/*`(若有)

---

## 五个独立任务,每个独立 commit checkpoint

按"风险从低到高"顺序执行:任务 1 → 任务 2 → 任务 3 → 任务 4 → 任务 5。
每个任务做完跑 `make test`,通过后 commit,再做下一个。

---

### 任务 1 — `.gitignore` 收尾(5 分钟)

**做什么**:把长期 untracked 的本地工作目录加入 `.gitignore`。

**修法**:在 `.gitignore` 末尾追加:

```
# 本地工具与 IDE 工作区
.sisyphus/
.vscode/
tmp/
```

**注意**:
- `dist/` 已经在 .gitignore 中(`make dev` / `make release` 产物)
- 不要顺手清理任何现有 .gitignore 条目
- 不要把 `.sisyphus/` `tmp/` 已存在的内容删掉

**验证**:`git status` 后 untracked 列表不再包含上面三项。

**checkpoint**:`git commit -m "Add local workspace dirs to .gitignore"`

---

### 任务 2 — `Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/main.swift` 拆分(2-3 小时)

**做什么**:把单文件 2000+ 行的测试按主题拆成多个文件,
`main.swift` 只保留 `ArchitectureTestRunner.main()` 入口和子模块调度。

**目标结构**:

```
Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/
├── main.swift                          # @main + 调度
├── Support/
│   ├── TestRunner.swift                # TestRunner / expect / require
│   ├── Fakes.swift                     # FakePermissionAccess / FakeOutputSink / ...
│   └── Fixtures.swift                  # RecognitionFinalizerHarness 等
├── PermissionTests.swift
├── ASRProviderTests.swift
├── RecognitionSessionTests.swift
├── RecordingStateMachineTests.swift
├── RecognitionFinalizerTests.swift
├── CapsuleAnimationTests.swift
├── AudioRouterTests.swift
├── LLMRefinerTests.swift
├── UpdateCheckerTests.swift
├── HeadphoneHIDTests.swift
├── PunctuationTests.swift
├── KeychainTests.swift
├── SherpaPreloadTests.swift
└── AppSettingsNotificationTests.swift
```

**修法**:

- 每个主题文件提供 `enum FooTests { static func run(_ runner: inout TestRunner) async { ... } }`。
- `main.swift` 变成:

  ```swift
  @main
  struct ArchitectureTestRunner {
      static func main() async {
          var runner = TestRunner()
          await PermissionTests.run(&runner)
          await ASRProviderTests.run(&runner)
          await RecognitionSessionTests.run(&runner)
          await RecordingStateMachineTests.run(&runner)
          // ...
          await runner.finish()
      }
  }
  ```

- 把 `TestRunner` struct、`expect` / `require` helper、`@testable import AtomVoiceCore` 
  等放到 `Support/TestRunner.swift`。
- 把 `FakePermissionAccess` / `RecognitionFinalizerHarness` 等 fake / fixture 
  放到 `Support/Fakes.swift` / `Support/Fixtures.swift`。

**注意**:

- SwiftPM 默认按目录递归扫描,`Package.swift` 不需要改(如有 `sources:` 显式列举,
  需要补对应路径)。
- 不修改任何测试**内容**,只拆文件位置。任何 case 的断言、setup、teardown 都保持原样。
- 测试**总数仍是 86 条**(round 2 完成后可能更多,用当时实际数字),不增不减。
- 拆分顺序:先拆 Support/ 帮助文件,再拆主题文件,最后改 main.swift。每拆一个文件
  立刻跑 `make test` 验证。

**验证**:

- `make test` 通过,测试数与拆分前一致。
- `wc -l Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/main.swift` < 50 行。

**checkpoint**:`git commit -m "Split architecture tests into per-topic files"`

---

### 任务 3 — CI 跑 `make test` + 编译检查(1 小时)

**做什么**:新增 GitHub Actions workflow,push 到 main 和 PR 时自动跑测试和编译检查。

**修法**:

新建 `.github/workflows/test.yml`:

```yaml
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: tests-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-14
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Show Swift version
        run: swift --version
      - name: Run architecture tests
        run: make test
      - name: Verify release build compiles (unsigned)
        run: swift build -c release
        env:
          CODE_SIGN_IDENTITY: "-"
```

**注意**:

- 不要尝试在 CI 跑 `make dev` —— 它依赖 Apple Development 证书,CI 没有。
- `swift build -c release` 作为编译验证,**不要**试图签名打包。
- 如果 macOS runner 默认 Xcode 不匹配,可加 `sudo xcode-select -s /Applications/Xcode_16.app`,
  但先用默认跑一次看版本。
- 现有 `.github/workflows/` 若已有 Gitee 同步等 workflow,保留,不要合并到 test.yml。
- 不要触发 `make sherpa-memory` 或其他重活。

**验证**:

- workflow 文件本地 YAML lint 通过(`yq` 或在线 validator)。
- 提交后在 GitHub Actions 页面手动确认首次 run 通过(用户验证,不要自己 push)。

**checkpoint**:`git commit -m "Add GitHub Actions workflow for tests and build check"`

---

### 任务 4 — 本地化 key 覆盖 lint(1-2 小时)

**做什么**:写一个脚本扫所有 `loc("xxx")` 调用,然后扫 8 个 `*.lproj/Localizable.strings`,
任何一个 lproj 缺 key 就报错。

**修法**:

- 新建 `Scripts/check_localization.swift`(可执行 Swift script)。
- 扫描所有 `Sources/AtomVoice/**/*.swift`,用正则提取 `loc\("([^"\\]+)"` 中的 key。
- 扫描所有 `Sources/AtomVoice/**/*.lproj/Localizable.strings`,提取 `"([^"]+)"\s*=` 中的 key。
- 对比 8 个 lproj(`en` / `zh-Hans` / `zh-Hant` / `ja` / `ko` / `es` / `fr` / `de`),
  报告:
  - 在源代码中调用但**某个 lproj 缺失**的 key
  - 在 lproj 中存在但**所有源代码都未调用**的 key(警告,不报错)
- 任何 lproj 缺 key → exit 1,详细列出缺哪个 key 在哪个 lproj。

**集成**:

- `Makefile` 加 target:

  ```makefile
  lint-loc:
  	swift Scripts/check_localization.swift
  ```

- `.github/workflows/test.yml` 加一个 step(在 `make test` 之后):

  ```yaml
  - name: Lint localization keys
    run: make lint-loc
  ```

**注意**:

- 脚本要处理 `loc("key", arg1, arg2)` 这种带参数形式,只看第一个参数是字符串字面量的情况。
- 跳过 `loc(variableName)` 这种动态 key —— 报警告,不报错。
- 跳过被注释的 `loc(` 调用(`//`、`/* */`)。
- `*.strings` 文件解析时注意 escape `\"` 和注释 `/* */` `//`。
- 第一次运行如果发现真实缺 key,**先报告给用户**,不要自动补 — 翻译需要用户决定。
  本任务只引入 lint **工具**,不修复历史缺失。
- 如果首次跑发现缺 key 太多,在脚本里默认 warn 而不 fail,加 `--strict` 选项让 CI 用。
  先 fix-forward,把现有缺失逐步补齐。

**验证**:

- `make lint-loc` 跑通,输出当前所有 lproj 完整性报告。
- 在 CI 中能跑通(不一定立刻 strict)。

**checkpoint**:`git commit -m "Add localization key coverage lint"`

---

### 任务 5 — `AppSettings` 拆 typed stores(半天到一天)

**做什么**:把 `AppSettings` 这个 static 全局门面拆成多个 typed store,
保持现有所有调用点编译通过,同时可在测试中注入 fake backend。

**修法**:

**Step 1 — 抽象 backend**

新建 `Sources/AtomVoice/Settings/SettingsBackend.swift`:

```swift
protocol SettingsBackend: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String, default: Bool) -> Bool
    func double(forKey key: String, default: Double) -> Double
    func integer(forKey key: String, default: Int) -> Int
    func set(_ value: Any?, forKey key: String)
    func register(defaults: [String: Any])
    func observe(key: String, handler: @escaping () -> Void) -> SettingsObservation
}

final class SettingsObservation { ... }   // 用 NSKeyValueObservation 包一层

final class UserDefaultsBackend: SettingsBackend { ... }
final class InMemorySettingsBackend: SettingsBackend { ... }   // 测试用
```

**Step 2 — 拆 typed stores**

根据现有 `AppSettings` 的字段分类,新建:

- `Sources/AtomVoice/Settings/RecognitionSettings.swift` — 识别引擎、Sherpa preset、识别语言等
- `Sources/AtomVoice/Settings/LLMSettings.swift` — LLM 开关、endpoint、结果延迟。**API key 仍走 Keychain**,不动 KeychainStore
- `Sources/AtomVoice/Settings/AudioSettings.swift` — 录音音量降低、Apple live insertion 开关
- `Sources/AtomVoice/Settings/OOBESettings.swift` — OOBE 是否完成、首启动版本
- `Sources/AtomVoice/Settings/UpdateSettings.swift` — 更新通道
- `Sources/AtomVoice/Settings/InterfaceSettings.swift` — 动画 style / speed / 触发键模式等 UI 偏好(如果有的话)

每个 typed store:

```swift
final class RecognitionSettings {
    private let backend: SettingsBackend
    private static let engineKey = "recognitionEngine"   // 保留旧 key 字符串
    private static let sherpaPresetKey = "sherpaModelPresetID"
    // ...

    init(backend: SettingsBackend) { self.backend = backend }

    var engine: String {
        get { backend.string(forKey: Self.engineKey) ?? "apple" }
        set {
            backend.set(newValue, forKey: Self.engineKey)
            NotificationCenter.default.post(name: Self.engineDidChange, object: nil)
        }
    }
    static let engineDidChange = Notification.Name("RecognitionSettings.engineDidChange")
    // ...
}
```

**Step 3 — `AppSettings` 改为 thin façade**

```swift
enum AppSettings {
    static let backend: SettingsBackend = UserDefaultsBackend(defaults: .standard)
    static let recognition = RecognitionSettings(backend: backend)
    static let llm = LLMSettings(backend: backend)
    static let audio = AudioSettings(backend: backend)
    static let oobe = OOBESettings(backend: backend)
    static let update = UpdateSettings(backend: backend)
    static let interface = InterfaceSettings(backend: backend)

    // 旧静态门面 — 保持调用点编译通过,内部委托给 typed store
    static var recognitionEngine: String {
        get { recognition.engine }
        set { recognition.engine = newValue }
    }
    static var normalizedRecognitionEngine: String { ... }
    static var lowerVolumeOnRecording: Bool {
        get { audio.lowerVolumeOnRecording }
        set { audio.lowerVolumeOnRecording = newValue }
    }
    // ... 其他所有现有静态 property 都保留,委托给 typed store
}
```

**关键**:**保持现有所有 `AppSettings.xxx` 调用点编译通过**。门面方法体可以变成
一行委托,但接口不变。这样不会有任何一处生产代码因为这次拆分需要改。

**Step 4 — 精确变化通知保持兼容**

`AppSettings.recognitionEngineDidChange` / `sherpaProviderDidChange` 等现有
通知名称保留,在 typed store 内部 post 同名通知(用户已有订阅者不会断)。

**Step 5 — 测试 backend 注入**

新建 `Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/AppSettingsBackendTests.swift`,
覆盖:
- `InMemorySettingsBackend` 的 get / set / observe 基础行为
- `RecognitionSettings` 切换 engine 后通知触发
- `LLMSettings` 启用后通知触发
- `AudioSettings` lowerVolumeOnRecording 默认值正确

**注意**:

- **不要改任何 UserDefaults key 字符串**(`recognitionEngine` / `sherpaProvider` /
  `sherpaModelPresetID` / `sherpaRecognitionLanguage` / `lowerVolumeOnRecording` /
  `llmEnabled` / `appleLiveInsertionEnabled` / OOBE / `animationStyle` /
  `animationSpeed` / `updateChannel` ... 等等),否则**已发版用户设置会被重置**。
- **不要动 KeychainStore**。LLM API key、Doubao API key 仍走 Keychain,
  typed store 只做"是否启用"等非密钥设置。
- **不要动 OOBE 引擎写入路径**。`OOBEWindow` 仍通过 `AppSettings.recognitionEngine = X`
  写入,内部委托到 `RecognitionSettings.engine`。
- **不要顺手改默认值**。现有默认值一行不动。
- 注释保持中文,日志保持中文。

**验证**:

- `make test` 通过,新增 typed store 测试 +5 条以上。
- `make dev` 通过,产物为 `dist/Test/AtomVoice.app`。
- 手动确认:启动 OOBE、切换识别引擎、修改 LLM 设置、修改更新通道,
  对应 UserDefaults key 写入磁盘内容与拆分前一致(可用 `defaults read xyz.AtomVoice` 验证)。

**checkpoint**:`git commit -m "Split AppSettings into typed settings stores"`

---

## 行为不变清单

任何一项偏移都必须立刻停下来报告。

- 现有 UserDefaults key 字符串完全不变
- 现有 Keychain key 完全不变
- 现有精确变化通知名称完全不变
- OOBE 首启动行为不变
- 现有所有 `AppSettings.xxx` 静态 property 调用点不需要改
- 任务 2 拆分后 `make test` 测试总数不变(只动文件位置)
- 任务 4 lint 默认 warn,strict 模式发现的缺失先报告,不自动补
- `dist/` 产物不被任何 .gitignore 改动影响
- CI 不签名,不 release,不打包

---

## 硬性约束

- 五个任务必须各自独立通过 `make test`,**分五个 commit**。
- 不顺手做其他重构:不改命名约定、不动 RecordingSessionController / Reducer / 
  RecognitionSession 等业务代码、不修历史 bug。
- 不新增 UserDefaults / Keychain key。
- 不复制重型 runtime owner。
- 自动化测试不得触发真实权限弹窗、打开系统设置、采集音频、访问云 ASR、
  下载或加载 Sherpa 模型。
- 任务 3 CI workflow 不要 push 自己(用户决定何时启用)。
- 任务 4 lint 报告的真实缺失项,**只汇报,不自动补翻译**。
- 任务 5 不允许"顺手优化" `AppSettings`:不删字段、不改默认值、不改通知名。

---

## 遇到阻塞的处理

- 任务 2 拆分发现某个测试依赖文件内顺序(比如全局可变 fixture 在 main.swift 中
  按顺序初始化),停下来,把那段 fixture 抽到 `Support/Fixtures.swift` 显式
  注入,不要让拆分后的测试隐式依赖文件顺序。

- 任务 4 lint 发现现有真实缺 key,在脚本里默认 warn 不 fail。CI step 用 `|| true`
  暂时不阻塞,等用户决定 strict 模式开启时机。

- 任务 5 若发现 `AppSettings` 某个字段实际不走 UserDefaults(比如纯 computed
  或 enum case),不要硬塞到 typed store,保留为 façade 上的 computed property。
  在报告中说明哪些字段保留在 façade 而非 typed store。

- 任何任务做到一半发现影响超过预期(比如任务 5 实际上需要改 ~100 个调用点),
  停下来,把该任务拆成 a / b 子步骤分别 checkpoint。

---

## 收尾

完成五个任务后,给出:

- 改动文件清单(按任务)
- 每任务 `make test` 通过条数
- 拆分前后 `Sources/AtomVoice/Debug/AtomVoiceArchitectureTests/` 目录结构
- `AppSettings.swift` 拆分前后行数
- 现有 UserDefaults key 完整列表(用于将来 lint)
- 现有 `loc()` 缺 key 报告(任务 4 产出)
- 在 `localdoc/decoupling-architecture-plan.md` 末尾追加本轮记录
- **不要运行 `make release`**
