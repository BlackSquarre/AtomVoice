# 粘贴兼容性优化（Paste Compatibility）

## 背景

`TextInjector` 把识别结果写入剪贴板后用 `Cmd+V` 注入到当前输入框。普通桌面应用 250ms 的等待足够；但远程桌面、虚拟机、游戏串流类应用自己实现了键盘转发层（VNC/RDP/网络/hypervisor/帧缓冲），同样的 `Cmd+V` 经常掉字符。

为这些应用单独使用更长的粘贴延迟即可解决。功能**默认启用、不暴露给用户**，新增应用直接改代码即可。

## 实现位置

| 文件 | 角色 |
|---|---|
| `Sources/AtomVoice/PasteCompatibilityProfile.swift` | 全部逻辑都在这一个文件里：分类枚举、内置清单、查找函数 |
| `Sources/AtomVoice/TextInjector.swift` | 在 `performInject()` 起始处调用注册表，命中则用类别延迟覆盖默认 |

## 数据结构

```swift
enum PasteCompatibilityCategory {
    case remoteDesktop    // 0.40s — 远程桌面/RDP/VNC/向日葵/ToDesk 等
    case virtualMachine   // 0.35s — 本地 VM（Parallels / VMware / UTM / virt-viewer）
    case gameStreaming    // 0.50s — 游戏串流（Parsec / Moonlight / Steam Link 等）
}

struct PasteCompatibilityProfile {
    let bundleID: String
    let displayName: String     // 仅用于代码可读性，不展示给用户
    let category: PasteCompatibilityCategory
}
```

每个类别对应一个延迟常量，**调参只需改类别上的 `pasteDelay`，不用动每条记录**。

## 注入流程

1. `TextInjector.performInject` 在主线程调用 `PasteCompatibilityRegistry.profileForFrontmostApp()`。
2. 通过 `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` 查 `bundleIDIndex` 字典。
3. 命中时把延迟取 `max(全局 pasteDelay, 类别 pasteDelay)`——不会让"优化"反而比用户调慢的全局延迟更短。
4. 没命中走原有逻辑，零开销（一次字典查询）。

## 增删应用 / 调整延迟

只要改一处文件：`Sources/AtomVoice/PasteCompatibilityProfile.swift`。

### 加新应用
在 `builtin` 数组里追加一行：

```swift
.init(bundleID: "com.example.newremote", displayName: "Example Remote", category: .remoteDesktop),
```

### 拿不到 bundleID 怎么办
1. 把目标应用打开，让它成为前台
2. 在终端跑：`osascript -e 'id of app (path to frontmost application as text)'`
3. 或更通用：`mdls -name kMDItemCFBundleIdentifier /Applications/那个App.app`

### 调整某一类的延迟
在 `PasteCompatibilityCategory.pasteDelay` 的 `switch` 里改对应数值。所有该类别的应用同步生效。

### 新增分类
在 `PasteCompatibilityCategory` 加 case + 对应延迟，然后在 `builtin` 里把应用归到新分类即可。

## 当前内置清单（不完整列表）

- **远程桌面（0.40s）**：Apple Screen Sharing、Apple Remote Desktop、Microsoft Remote Desktop、TeamViewer、AnyDesk、RealVNC、Jump、Splashtop、Citrix、NoMachine、RustDesk、Royal TSX、Devolutions、VMware Horizon、Amazon WorkSpaces、向日葵、ToDesk、网易 UU 远程、RayLink、GotoHTTP 等
- **虚拟机（0.35s）**：Parallels、VMware Fusion、UTM、virt-viewer / SPICE
- **游戏串流（0.50s）**：Parsec、Moonlight、Steam Link、PS Remote Play

完整列表以 `PasteCompatibilityProfile.swift` 里的 `builtin` 数组为准。

## 故意没做的事

- **未做远程更新**：清单跟随版本发布更新，不引入网络依赖。
- **未做用户白名单 UI**：免维护是核心目标；用户能调的全局 `pasteDelay` 已经足够覆盖兜底场景。
- **未做启发式判断**（如按 bundleID 关键字 `remote`/`rdp`/`vnc` 匹配）：误判风险大于收益。
- **未做逐字符模拟键入**：CJK 输入法兼容性差，且当前 0.40~0.50s 的粘贴延迟在实测中已能解决绝大多数远程桌面应用的丢字问题。
