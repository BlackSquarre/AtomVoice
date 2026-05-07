# OOBE 首次启动引导窗口

> 状态：✅ 已完成（branch `开屏页`）

本文档介绍 AtomVoice 首次启动引导（Out-of-Box Experience）窗口的实现方式，方便后续维护者或 AI 助手理解架构、扩展步骤或调整文案。

## 1. 目标

新用户第一次打开 AtomVoice 时，引导他们：

1. 了解产品定位（轻盈、隐私优先、任意 App 通用）。
2. 授予三项系统权限（辅助功能 / 麦克风 / 语音识别）。
3. 选择触发按键和触发方式（长按 / 单击）。
4. 选择识别引擎（按隐私 高 → 低 排列：本地 / Apple / 豆包）。
5. 完成并直接落到对应后续动作（豆包 → 打开设置；Sherpa → 提示下载模型）。

完成后写入 `UserDefaults.hasCompletedOOBE = true`，下次启动不再弹出。可在菜单栏「重新运行设置引导...」手动触发。

## 2. 文件结构

| 文件 | 角色 |
| --- | --- |
| `Sources/AtomVoice/OOBEWindow.swift` | 引导窗口控制器、5 个步骤视图、引擎卡、键盘示意图、权限卡 |
| `Sources/AtomVoice/AppDelegate.swift` | 首次启动判断 + `showOOBE()` + `onFinish` 回调串起后续动作 |
| `Sources/AtomVoice/MenuBarController.swift` | 「重新运行设置引导」菜单项；`openDoubaoSettingsFromOutside()` / `rebuildMenuPublic()` 桥接 |
| `Resources/*.lproj/Localizable.strings` | 8 种语言全部 OOBE 文案（key 前缀 `oobe.*`） |

只新增了一个文件 (`OOBEWindow.swift`)，其他都是小幅改动。

## 3. 数据流

```text
applicationDidFinishLaunching
  └─ UserDefaults.hasCompletedOOBE == false
        └─ AppDelegate.showOOBE()
              └─ OOBEWindowController.showWindow()
                    ├─ Step 0 Welcome    (makeWelcomeStep)
                    ├─ Step 1 Permissions(makePermissionsStep)
                    ├─ Step 2 Trigger Key(makeTriggerKeyStep)
                    ├─ Step 3 Engine     (makeEngineStep)
                    └─ Step 4 Done       (makeDoneStep)
                          └─ finish()
                                ├─ 写 UserDefaults: hasCompletedOOBE / recognitionEngine / triggerKeyCode
                                └─ onFinish?(engine, triggerKey)
                                       └─ AppDelegate
                                            ├─ fnKeyMonitor.triggerKeyCode = triggerKey
                                            ├─ menuBarController.rebuildMenuPublic()
                                            └─ 引擎分支：
                                                 - sherpaOnnx → promptSherpaDownloadPublic()
                                                 - doubao     → openDoubaoSettingsFromOutside()
                                                 - apple      → noop
```

## 4. 窗口骨架（OOBEWindowController）

固定尺寸 760×560，`.titled + .closable`，无 `resize`、无 `miniaturize`。

```
┌─────────────────────────────────────────────────────┐
│              [ • • ● • • ]    步骤指示器 (顶部居中)   │
│                                                     │
│              contentContainer                       │
│         (每一步 stepView 替换填充)                   │
│                                                     │
│  [ 返回 ]                            [ 继续 / 开始 ] │
└─────────────────────────────────────────────────────┘
```

- **步骤切换**：`showStep(_:)` 清空 `contentContainer.subviews` 后重建当前步骤的视图；`backButton.isHidden = (step == 0)`，最后一步把"继续"改成"开始使用"。
- **进度点**：`titleDots[i].layer.backgroundColor` 在 `controlAccentColor` / `tertiaryLabelColor` 切换。
- **关闭按钮**：保留 X，等同于"跳过"——不写 `hasCompletedOOBE`，下次启动还会再弹。

## 5. 各步骤实现要点

### Step 0 — Welcome

中央竖向堆叠：图标 → 主标题 → **Tagline** → **副标** → 提示。

三层文案分主次：
- `oobe.welcome.title`：26pt semibold（应用名）
- `oobe.welcome.tagline`：16pt medium，labelColor（核心 slogan）
- `oobe.welcome.subtitle`：13pt secondary（功能说明）
- `oobe.welcome.hint`：12pt tertiary（行动召唤）

### Step 1 — Permissions

3 张横向并排的**竖版卡片**（`OOBEPermissionCardView`），每张：
```
┌─────────┐
│ [Icon]  │  彩色 SF Symbol (28pt)
│ 标题     │
│ 描述     │
│ ─────   │  分隔线
│ ● 状态   │
│ [按钮]   │
└─────────┘
```

- 用 SF Symbol：`accessibility` / `mic.fill` / `waveform`，颜色分别 systemBlue / systemPink / systemPurple。
- 状态由独立 1.5s 定时器轮询（`startPermissionRefresh`），分别检查 `AXIsProcessTrusted()`、`AVCaptureDevice.authorizationStatus(for: .audio)`、`SFSpeechRecognizer.authorizationStatus()`。
- 点击按钮：`notDetermined` 状态走 `requestAccess` 触发系统弹窗；其他状态打开「系统设置」对应面板。
- `PermissionStatus` 枚举在 `PermissionsWindow.swift` 定义，OOBE 复用。

### Step 2 — Trigger Key

包含两部分：

**键盘示意图（`KeyboardDiagramView`）**：用 `NSView + NSStackView` 代码绘制 mac 笔记本底排键盘，**不使用任何位图资源**——保持包体积小。
- 顶部 2 行装饰键（灰色矩形，不可点击）。
- 底排修饰键：4 个候选键（`fn` / 右 ⌘ / 右 ⌥ / 右 ⌃）以彩色边框标记可点击；其余装饰。
- 选中时整键填充 `controlAccentColor`，文字白色。
- `keyCode` 与 `TriggerKeyOption` 对齐：63 / 54 / 61 / 62。

**触发方式分段控件**：`NSSegmentedControl` 「长按说话 / 单击说话」，写入 `UserDefaults.silenceAutoStopEnabled`，下方动态描述。

### Step 3 — Engine

3 张横向竖版卡片（`EngineCardView`），左→右隐私由高到低：

| 顺序 | 引擎 | 隐私 | 颜色点 | 费用样式 |
| --- | --- | --- | --- | --- |
| 1 | Sherpa 本地离线 | 本地推理 | 🟢 | 免费（绿）+ 灰色副本「需下载模型」 |
| 2 | Apple 语音 | Apple 本地 + 云端 | 🟡 | 免费（绿） |
| 3 | 豆包流式 | 纯云端 | 🔴 | 付费（橙信用卡） |

每张卡结构（自上而下）：
1. SF Symbol 大图标（30pt）
2. 标题 + 可选 Badge（如"推荐"）
3. Tagline（一句话定位）
4. 属性区：
   - 隐私行：彩色圆点 + 文字
   - 费用行：✓/💳 图标 + 主文 + 灰色副本（footnote）
   - **星级独立行**：5 颗 16pt 星 + 评级文字
5. 分隔线
6. 描述

`EngineCardModel.CostStyle` 决定费用图标 + 颜色（`.free` 绿 ✓ / `.paid` 橙 信用卡）。`costFootnote` 用于本地离线模型的"需下载模型"灰色副本，紧跟在主文之后。

选中状态：卡片边框 `controlAccentColor`，2pt 厚度。

### Step 4 — Done

居中：✓ 大对勾 → "一切就绪" → 引导正文（用 `%@` 注入选中触发键符号）→ 跟随选中引擎的后续提示文案（提示打开豆包设置 / 提示下载模型 / 提示 Apple 离线）。

## 6. 关键设计决策

### 为什么所有视图都用代码绘制？
没有 `.xib` / `.storyboard`，没有 PNG/SVG 资源。键盘示意图、星级、隐私圆点、引擎图标都用 `NSView` 或 SF Symbol。**好处**：包体积小、深浅色自适应、可主题化、无需 asset catalog 维护。

### 为什么权限页用横排卡片而不是行式列表？
和后面引擎页的视觉语言对齐——3 张横排竖向卡片是 OOBE 的统一容器单元。早期版本的"上下行式排版"按钮占满整行，视觉太重。

### 为什么星级单独一行而不是和文字内联？
5 颗 16pt 星横向跨度大，挤进属性行会撑爆 / 截断。单独成行后有足够空间，也成为引擎卡的视觉亮点。

### Debug Build 的差异
此窗口不区分 Debug / Release，文案、流程一致。`#if DEBUG_BUILD` 仅用于「关于」窗口角标和胶囊计时器（见 CLAUDE.md）。

## 7. 文案与本地化

所有用户可见字符串通过 `loc("oobe.*")` 走 `Localizable.strings`，覆盖 8 种语言。新增 OOBE 文案时**必须同步 8 个 lproj 文件**，否则会回退到 key 名。

**中文连写规则**：中文之间不加空格（如「欢迎使用原子微语」、「原子微语需要权限」）；中文与数字 / 拉丁字符之间保留盘古之白（如「原子微语 %@ 已发布」）。

主要 key 前缀：

| 前缀 | 用途 |
| --- | --- |
| `oobe.welcome.*` | Step 0：title / tagline / subtitle / hint |
| `oobe.perm.*` | Step 1 标题与副标 |
| `oobe.trigger.*` | Step 2：标题、副标、选中提示、模式分段控件文案 |
| `oobe.engine.*` | Step 3：每个引擎的 title / tagline / desc + 隐私 / 费用 / 星级评级 |
| `oobe.done.*` | Step 4：标题、引导正文、按引擎分支的后续提示 |
| `permission.*` | 各权限的 title / desc / 状态 / 操作按钮（与 PermissionsWindow 共用） |

## 8. 如何扩展 / 修改

### 增加一个步骤

1. 把 `totalSteps = 5` 改为 6。
2. `showStep(_:)` 的 switch 中插入 `case N: stepView = makeXxxStep()`。
3. 写一个 `makeXxxStep() -> NSView`，参考其他步骤的 `NSStackView` 排版。
4. 在所有 8 个 lproj 加 `oobe.xxx.*` 文案。

### 增加一个引擎卡

在 `makeEngineStep()` 的 `entries: [EngineCardModel]` 里新增一项，按隐私级别决定排在何处。如果是付费云端，`costStyle = .paid` 即可。

### 改变默认选中

修改 `OOBEWindowController` 的 `selectedEngine` / `selectedTriggerKeyCode` 默认值；`showWindow()` 优先读 `UserDefaults`，无值才用默认。

### 强制重弹引导

`defaults delete com.blacksquarre.AtomVoice hasCompletedOOBE` 后重启 App。或在菜单栏点「重新运行设置引导...」。
