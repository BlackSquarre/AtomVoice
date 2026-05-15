# 内存占用排查与优化记录（2026-05-16）

## 起因

`v0.10.2-Beta-5` 把"辅助窗口关闭后释放控制器"作为内存优化项。用户继续问"还能做什么"，于是做了一次系统性测量。

## 测量基础设施

新增 `Sources/AtomVoice/MemoryProbe.swift`：

- 用 `task_vm_info.phys_footprint` 拿进程驻留内存（与 Xcode "Memory" 标签一致的数字）
- `MemoryProbe.log("tag") -> 写一行 [MemoryProbe] tag -> X.X MB` 到 `~/Library/Logs/AtomVoice/debug.log`
- 探针只在 `DEBUG_BUILD` 下编译进去；release 构建里 release-build 里没有调用点

固定的探针位置（都在 `#if DEBUG_BUILD` 内）：

| 位置 | 标签 |
|---|---|
| `AppDelegate.applicationDidFinishLaunching` | `launch` / `idle-5s-after-launch` |
| `session.onRecordingStateChanged` | `recording-start` / `recording-stop` / `recording-idle-3s` |
| `MenuBarController.selectRecognitionEngine` | `engine-switch-before X -> Y` / `engine-switch-after Y`（1s 后） |
| 菜单栏 debug 项手动触发 | `manual-dump` |

排查 Sherpa 期间还加过细粒度探针（`sherpa.stop` / `sherpa.punct` / `sherpa.release`），完成定位后已移除。

## 关键发现

启动 idle 基线 **14 MB**。三种引擎对比：

| 引擎 | 录音中峰值 | 录音停止后 | 切走 + 释放后 | 长时间 idle |
|---|---|---|---|---|
| Apple Speech | ~32 MB | ~33 MB | / | / |
| Doubao 云端 | ~212 MB | ~212 MB | / | / |
| Sherpa 本地 | ~640 MB | **+220 MB spike → 690 MB** ⚠️ | ~215 MB | ~92 MB |

Apple 和 Doubao 都很温和。Sherpa 是大头，并且有两个奇怪点：

1. **stop 后 +220MB**：录音停止后内存还在涨
2. **释放后 80MB 残留**：完全 destroy 也回不到启动 baseline

## 已实施的优化

### 1. 标点模型与主识别器同生命周期

`SherpaOnnxRecognizerController.start()` 加载主识别器后**立即同步加载标点模型**，不再等到首次调用 `punctuate()` 时懒加载。

- 之前：录音 stop 时第一次调 `punctuate()` → 触发标点模型加载 → +220MB spike
- 之后：录音 start 时就把两个模型一并加载，stop 后内存曲线平稳

实测：`recording-stop` → `recording-idle-3s` 增量从 **+226 MB** 降到 **+15 MB**。

注意：**这不是真的省内存**，只是把内存预算挪到了"用户主动选用 Sherpa 录音"的时刻。但好处是：
- 没有 stop 后的内存突增 spike
- 低内存机器更可预期（用户开始录音时就知道代价，不会在 stop 后被推进 swap）
- 释放也成对：`releaseModels()` 同时销毁 `context` + `punctuationContext`，逻辑更对称

修改位置：`Sources/AtomVoice/SherpaOnnxRecognizer.swift` 的 `start()` 函数，在 main context 创建后调 `_ = ensurePunctuationContext()`。

### 2. malloc pressure relief（实测无效，保留作占位）

`ASREngineProvider.releaseSherpaEngine()` 在销毁 Sherpa 后调用 `malloc_zone_pressure_relief(nil, 0)`。

预期：把 Sherpa 释放后空闲但仍计入 RSS 的 arena 页归还系统。
实测：在 macOS Sequoia 上只能回收 **16 KB**，对 80MB 残留来说基本是零。

保留这一行的原因：开销几毫秒，无副作用，未来 macOS 改进时可能生效。

## 没做但讨论过的优化（及不做的原因）

| 想法 | 预期节省 | 不做的原因 |
|---|---|---|
| AudioEngine 懒创建 | < 3 MB | 数据证明 AudioEngine 不是大头，节省额度小于改造引入的首次录音延迟风险 |
| Apple / Volcengine 引擎切换时释放 | < 2 MB | 数据证明它们驻留极小，且重新加载会增加延迟 |
| Sherpa 子进程化 | **80 MB**（ONNX 全局 + arena 碎片，**唯一能彻底回收的办法**） | 1-2 天重构 + IPC 复杂性 + 录音首启动延迟 ~200ms。投入产出比目前不值 |
| 用启发式标点替换 Sherpa 标点模型 | 220 MB | 启发式只能补句末标点，做不了句中逗号/顿号；影响 Sherpa 用户的标点质量 |
| 标点模型独立短 idle 卸载（如 30 秒） | 220 MB（idle 时） | 与用户要求的「标点与主模型生命周期同步」冲突；连续录音用户体验也会受影响 |

## 80 MB 残留的真相

Sherpa 完全 destroy 后仍有约 80 MB 残留，原因（按贡献度估算）：

1. **ONNX runtime C++ 静态全局**：thread pool、kernel registry、allocator caches 等 C++ 静态对象，`dlclose` 时**不会调用析构函数**（macOS dyld 限制）。一旦 ONNX 在进程里出生，它的全局状态就跟到进程死。
2. **libsystem_malloc 不归还页**：进程峰值用过 660 MB，malloc 内部 arena 增长到那个尺寸后**永远不会主动 munmap**。free 只是把内存还给 malloc，不是还给 OS。
3. **dlclose 引用计数残留**：sherpa lib 用 `RTLD_GLOBAL` 加载，符号可能交叉，dlclose 不一定 unmap。

OS 会随时间慢慢回收一部分（实测 15 秒后 215 MB → 92 MB），这部分不是我们能控制的。

## 测量入口（如何重跑）

1. `make dev` 编译并安装到 `dist/Test/AtomVoice.app`
2. `truncate -s 0 ~/Library/Logs/AtomVoice/debug.log` 清空 log
3. `open dist/Test/AtomVoice.app` 启动 dev 版本
4. 跑场景：等启动稳定 → 切引擎 → 录音 → 切回 → 等 30s 后点菜单里的 `Memory: XX.X MB` 项手动 dump
5. `grep MemoryProbe ~/Library/Logs/AtomVoice/debug.log` 查所有快照
