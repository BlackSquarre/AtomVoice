# 耳机线控 HID 来源证明 — 2026-05-18

## 背景

`HeadphoneMonitor` 在 `CGEvent` / `NSEvent` 层看到的是 `NX_SYSDEFINED`
里的 `NX_KEYTYPE_PLAY(16)`。这个事件已经被 macOS 抽象成“播放/暂停命令”，
不会稳定暴露物理来源。因此在耳机作为当前输出设备时，键盘媒体键和部分耳机线控
可能长得一样，继续只靠 `AudioOutputProbe.isHeadphoneOutputActive()` 会误触发录音。

AirPods Pro 握柄已经在 `2026-05-17-airpods-stem-control-investigation.md`
中关闭，不在本方案里恢复。

## 实现策略

新增 `HeadphoneHIDSourceMonitor`，用 `IOHIDManager` 监听 HID Consumer Control
设备的 Play / Pause / PlayOrPause 输入值。它不直接触发录音，只记录最近一次可信
Play/Pause 来源的时间戳。

`HeadphoneMonitor` 收到 `NX_KEYTYPE_PLAY` 时仍先检查：

1. 用户已开启耳机按钮输入；
2. 当前输出设备是耳机类；
3. 150ms 窗口内有 `HeadphoneHIDSourceMonitor` 记录的可信来源。

只有三者都成立，才把这次按压交给原有单击 / 双击 / 长按状态机。按下时完成来源证明，
松开事件沿用同一次可信按压，避免长按超过 150ms 后被误放行。

`HeadphoneHIDSourceMonitor` 只提供来源证明；真正的事件接管仍在 `HeadphoneMonitor`
的 `NX_KEYTYPE_PLAY` 路径中完成。因此键盘音量键、耳机音量键、亮度键等非 PLAY
媒体键都会直接 pass through，不参与 AtomVoice 触发。

## 乐观录音与延迟展示

为了避免单击录音丢掉 `doubleTapWindow` 内的开头语音，同时不让双击时胶囊闪现，
耳机单击说话使用“录音先行、展示延迟”的策略：

- 当前未录音、且处于单击说话模式时，第一次 Play/Pause 按下立即启动录音和 ASR；
- 280ms 双击等待期内不显示胶囊，也不触发流式上屏或 Apple live insertion；
- 如果 280ms 内第二次点击成立为双击，则取消这次录音并丢弃等待期音频，然后执行双击回车；
- 如果没有第二次点击，则确认单击，显示胶囊，并把等待期内已有的识别文本/状态接上；
- 当前已经录音时不做乐观停止，仍等双击窗口落定后再按单击处理，避免双击回车先把录音错误停止。

该策略由 `HeadphoneInputCoordinator` 调用 `RecordingSessionController.startDeferringCapsulePresentation()`
启动。`RecordingSessionController` 会先启动音频和 ASR，但缓存胶囊展示、波形、扫光、识别文本、
流式上屏和 Apple live insertion 的用户可见副作用；`revealDeferredCapsulePresentation()`
后再统一放出。双击成立时走 `session.cancel()`，等待期音频和识别结果一起丢弃。

该策略只改变可信 Play/Pause 进入状态机后的时序，不放宽 HID 来源判定。

## 可信来源判定

`HeadphoneHIDSourceClassifier` 使用 HID device 属性做保守判定：

- 必须是 Consumer Control 设备；
- 必须不是 built-in 设备；
- 必须不 conform 到 Generic Desktop Keyboard；
- 必须没有键盘相关 HID 属性提示（如 KeyboardUsageMap、SupportedKeyboardUsagePairs）；
- 必须没有 Keyboard usage；
- 产品名 / 厂商名中出现 keyboard、Magic Keyboard、Keychron、MX Keys、keypad、kbd、
  USB Receiver、Wireless Receiver 等模糊键盘接收器特征时拒绝；
- 产品名 / 厂商名中出现 AirPods 时拒绝；
- 接受 USB、Bluetooth、BluetoothLowEnergy；
- `transport=Audio` 只在产品名 / 厂商名明确像 Headset、Headphone、Earphone、Earbuds 时接受，
  用于 3.5mm 有线耳机中键。音量键和其它非 PLAY 媒体键仍由 `HeadphoneMonitor` 放行。

拒绝未知 transport 是有意的安全默认值：如果设备没有在 IOHID 层暴露足够来源信息，
就放行原始媒体键，不触发 AtomVoice。

## 日志

日志前缀为 `[HeadphoneHIDSource]`。

- 可信来源会打印 decision reason 和 device descriptor；
- 被拒绝来源会打印拒绝原因和 device descriptor；
- `HeadphoneMonitor` 因缺少来源证明放行 PLAY 时，会打印
  `[HeadphoneMonitor] 放行 PLAY：缺少可信 HID 来源证明`。

这些日志用于判断具体耳机是否支持安全识别，不能作为 AirPods 或未知来源的猜测规则。

## 已知边界

- 不支持 AirPods Pro 握柄专有路径。
- 不使用 `keyCode=0/1/4`、`data1` 序列或时间模式猜来源。
- 对只在 `CGEvent` 层出现、IOHID 层没有来源证明的耳机，默认不接管。
- `NX_SUBTYPE_AUX_MOUSE_BUTTONS` 的 MAY 双击回车兼容逻辑仍按原来的录音窗口约束处理；
  它不用于开始录音，也不作为 Play/Pause 来源证明。

## 验证

- `make test` 通过 35 条架构测试。
- 新增测试覆盖：
  - USB 非键盘 Consumer Control 被信任；
  - 带 Keyboard usage 的 Consumer Control 被拒绝；
  - 未知 transport 默认拒绝；
  - AirPods 名称默认拒绝。
  - 键盘属性提示和模糊 USB receiver 名称默认拒绝。
  - 命名明确的 Audio headset control 被信任，泛化 Audio Consumer Control 被拒绝。

手工验证：

- USB 耳机中键可触发录音；
- 3.5mm 有线耳机中键可触发录音；
- 连接耳机时，内置键盘 / 外置键盘播放键不触发录音；
- 单击耳机中键后立即开始收音，胶囊约 280ms 后出现，开头语音不丢；
- 双击耳机中键不显示胶囊，等待期录音被取消，并发送回车；
- 音量键不被 AtomVoice 接管。
