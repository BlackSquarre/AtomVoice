# HLD: 豆包云端语音识别引擎接入

> **状态标记**: ✅ 已完成 | 🔧 部分完成 | ⏳ 待实现 | ❌ 未开始

## 1. 概览

本文设计将火山引擎“豆包语音”大模型流式语音识别 API 接入 AtomVoice，作为第三个识别引擎，与现有 Apple Speech Recognition 和 Sherpa-ONNX 并列。

目标实现路径是：复用现有录音、胶囊 UI、LLM 润色和文本注入链路；新增一个 WebSocket ASR 控制器，负责鉴权、协议封包、音频格式转换、流式发送和服务端响应解析。

## 2. 当前架构

当前录音链路：

```text
FnKeyMonitor
  -> AppDelegate.startRecording()
  -> AudioEngineController.start()
  -> Recognition Engine
  -> CapsuleWindowController.updateText()
  -> AppDelegate.stopRecording()
  -> optional LLMRefiner
  -> TextInjector.inject()
```

现有识别引擎：

| 引擎 | 接入方式 | 音频输入 |
| --- | --- | --- |
| Apple Speech Recognition | `SFSpeechAudioBufferRecognitionRequest` | `recognitionRequest.append(buffer)` |
| Sherpa-ONNX | 自定义 controller | `audioBufferHandler` 回调 `AVAudioPCMBuffer` |

豆包 ASR 应采用 Sherpa-ONNX 的接入方式，通过 `audioBufferHandler` 接收实时音频 buffer。

## 3. 目标架构

```text
AppDelegate
  -> VolcengineASRRecognizerController
       -> URLSessionWebSocketTask
       -> VolcengineASRProtocolCodec
       -> VolcengineAudioConverter
       -> VolcengineASRSettings
  -> AudioEngineController
       -> audioBufferHandler(buffer)
  -> CapsuleWindowController
  -> LLMRefiner
  -> TextInjector
```

新增模块建议：

| 模块 | 责任 |
| --- | --- |
| `VolcengineASRRecognizerController` | 生命周期、WebSocket 建连、发送音频、接收结果、对外暴露 start/accept/stop/cancel |
| `VolcengineASRProtocolCodec` | 火山二进制协议封包和解包 |
| `VolcengineAudioConverter` | `AVAudioPCMBuffer` 转 `16kHz mono pcm_s16le` 并按 200ms 分包 |
| `VolcengineASRSettings` | 读取 endpoint、API Key、Resource ID、语言和识别参数 |
| `KeychainStore` | 保存豆包 API Key，避免明文写入 UserDefaults |

## 4. 数据流

### 4.1 开始录音

```text
User presses trigger key
  -> AppDelegate checks selected engine == volcengineASR
  -> validate API Key and Resource ID
  -> show capsule
  -> VolcengineASRRecognizerController.start(onResult:onError:)
  -> open WebSocket with auth headers
  -> send full client request JSON frame
  -> AudioEngineController.start(audioBufferHandler:)
```

### 4.2 录音中

```text
AVAudioEngine tap emits AVAudioPCMBuffer
  -> VolcengineAudioConverter converts to 16k mono int16 PCM
  -> chunker accumulates about 200ms audio
  -> ProtocolCodec builds audio-only frame
  -> WebSocket sends binary data
  -> receive loop parses server response
  -> extract result.text
  -> onResult(text, isFinal)
  -> CapsuleWindowController.updateText(text)
```

### 4.3 停止录音

```text
User releases trigger key
  -> AudioEngineController.stop()
  -> VolcengineASRRecognizerController.stop()
  -> send final audio-only frame
  -> wait for final server response or timeout
  -> return final text to AppDelegate
  -> existing auto punctuation / LLM / injection flow
```

### 4.4 取消录音

```text
User presses ESC or app switches
  -> AudioEngineController.stop()
  -> VolcengineASRRecognizerController.cancel()
  -> cancel WebSocket task
  -> clear callbacks and buffered text
  -> dismiss capsule without injection
```

## 5. 火山接口配置

默认 endpoint：

```text
wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
```

首版使用新版控制台鉴权：

| Header | 值 |
| --- | --- |
| `X-Api-Key` | 用户配置的 API Key |
| `X-Api-Resource-Id` | 用户配置的 Resource ID |
| `X-Api-Request-Id` | 每次录音生成的 UUID |
| `X-Api-Connect-Id` | 每次连接生成的 UUID |
| `X-Api-Sequence` | `-1` |

默认 Resource ID 建议：

| 资源 | Resource ID |
| --- | --- |
| ASR 2.0 小时版 | `volc.seedasr.sauc.duration` |
| ASR 2.0 并发版 | `volc.seedasr.sauc.concurrent` |
| ASR 1.0 小时版 | `volc.bigasr.sauc.duration` |
| ASR 1.0 并发版 | `volc.bigasr.sauc.concurrent` |

## 6. 请求参数

首版 full client request JSON：

```json
{
  "user": {
    "uid": "atomvoice-macos"
  },
  "audio": {
    "format": "pcm",
    "codec": "raw",
    "rate": 16000,
    "bits": 16,
    "channel": 1,
    "language": "zh-CN"
  },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": true,
    "enable_ddc": false,
    "enable_nonstream": true,
    "show_utterances": true,
    "result_type": "full"
  }
}
```

语言映射：

| AtomVoice | 火山参数 |
| --- | --- |
| `zh-CN` | `zh-CN` |
| `zh-TW` | `zh-CN` + `output_zh_variant: traditional` 或 `tw` |
| `en-US` | `en-US` |
| `ja-JP` | `ja-JP` |
| `ko-KR` | `ko-KR` |
| `es-ES` | `es-MX` |
| `fr-FR` | `fr-FR` |
| `de-DE` | `de-DE` |

## 7. WebSocket 二进制协议

### 7.1 编码策略

首版建议使用 no compression，减少 gzip 依赖和实现复杂度。文档协议支持 `Message Compression = 0b0000`。如果联调发现服务端实际要求 gzip，再切换到 libz gzip 实现。

基础 header：

| 字段 | 值 |
| --- | --- |
| Protocol version | `0b0001` |
| Header size | `0b0001`，即 4 字节 |
| Serialization: JSON | `0b0001` |
| Serialization: none | `0b0000` |
| Compression: none | `0b0000` |

full client request：

```text
header[0] = 0x11
header[1] = 0x10
header[2] = 0x10
header[3] = 0x00
payload_size = UInt32 big-endian
payload = request JSON UTF-8 bytes
```

audio-only request：

```text
header[0] = 0x11
header[1] = 0x20 for normal audio, 0x22 for final packet
header[2] = 0x00
header[3] = 0x00
payload_size = UInt32 big-endian
payload = pcm_s16le bytes
```

### 7.2 响应解析

服务端 full response：

```text
4-byte header
4-byte sequence
4-byte payload_size
payload JSON
```

解析规则：

1. 读取 header size，跳过可选扩展 header。
2. 如果 message type 是 full server response，读取 sequence 和 payload size。
3. 如果 compression 是 gzip，先解压 payload。
4. JSON 中优先读取 `result.text` 作为当前完整文本。
5. 如果 `utterances` 存在且最后一个分句 `definite == true`，可将回调 `isFinal` 标记为 true。
6. 如果 message type 是 error response，读取错误码和错误消息，回调错误。

## 8. 音频转换

输入来自 `AVAudioEngine` 的 `AVAudioPCMBuffer`，通常为设备采样率、Float32、多声道。

输出要求：

| 字段 | 值 |
| --- | --- |
| sample rate | 16000 Hz |
| channels | 1 |
| sample format | signed 16-bit little-endian PCM |
| chunk duration | 200ms |

实现建议：

1. 使用 `AVAudioConverter` 将输入格式转换为 `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)`。
2. 将 Float32 样本 clamp 到 `[-1.0, 1.0]`。
3. 转为 Int16 little-endian。
4. 累积到 `chunkBuffer`，每 3200 samples 发送一包，即 200ms。
5. stop 时发送剩余样本，并使用 final packet flag。

## 9. 状态机

```text
idle
  -> connecting
  -> ready
  -> streaming
  -> finishing
  -> completed

idle
  -> connecting
  -> failed

streaming
  -> cancelling
  -> idle

finishing
  -> failed
```

状态说明：

| 状态 | 说明 |
| --- | --- |
| `idle` | 无连接、无缓冲 |
| `connecting` | 正在建立 WebSocket |
| `ready` | WebSocket 已建立，已发送 full client request |
| `streaming` | 正在发送音频并接收结果 |
| `finishing` | 已发送 final packet，等待最终响应 |
| `completed` | 已拿到最终文本 |
| `failed` | 连接、协议或服务端错误 |
| `cancelling` | 用户取消，禁止后续回调污染 UI |

## 10. 并发模型

建议使用专用串行队列保护 WebSocket 状态和音频缓冲：

```swift
private let queue = DispatchQueue(label: "com.atomvoice.volcengineASR")
```

线程规则：

1. `start`、`accept`、`stop`、`cancel` 将状态变更派发到串行队列。
2. `URLSessionWebSocketTask.receive` 回调进入串行队列解析。
3. 所有 UI 回调切回主线程。
4. `cancelled` 标志用于丢弃已排队但过期的回调。
5. 同一时间只允许一个活跃 WebSocket task。

## 11. AppDelegate 集成

新增属性：

```swift
private var volcengineRecognizer: VolcengineASRRecognizerController!
```

启动初始化：

```swift
volcengineRecognizer = VolcengineASRRecognizerController()
```

录音分支：

```text
if currentRecordingEngine == "volcengineASR" {
    startVolcengineRecording()
} else if currentRecordingEngine == "sherpaOnnx" {
    startSherpaRecordingAfterModelLoad()
} else {
    startAppleRecording()
}
```

停止分支：

```text
recognizedText =
  currentRecordingEngine == "volcengineASR" ? volcengineRecognizer.stop() :
  currentRecordingEngine == "sherpaOnnx" ? sherpaRecognizer.stop() :
  speechRecognizer.stop()
```

注意：豆包 ASR 的 `stop()` 可能需要异步等待最终响应。现有 `stopRecording()` 当前是同步取字符串，建议新增异步停止路径，避免阻塞主线程。

建议接口：

```swift
func stop(completion: @escaping (String) -> Void)
```

Sherpa 和 Apple 可继续同步，但 AppDelegate 停止流程需要抽象成异步 completion，以兼容云端最终响应。

## 12. 设置与存储

UserDefaults key 建议：

| Key | 类型 | 说明 |
| --- | --- | --- |
| `recognitionEngine` | String | 新增值 `volcengineASR` |
| `volcengineASREndpoint` | String | WebSocket endpoint |
| `volcengineASRResourceID` | String | Resource ID |
| `volcengineASREnablePunctuation` | Bool | 标点 |
| `volcengineASREnableITN` | Bool | ITN |
| `volcengineASREnableDDC` | Bool | 顺滑 |
| `volcengineASREnableNonstream` | Bool | 二遍识别 |
| `volcengineASRPrivacyAccepted` | Bool | 首次启用云端提示确认 |

API Key 存储：

| 项 | 决策 |
| --- | --- |
| 存储位置 | Keychain |
| service | `com.blacksquarre.AtomVoice.volcengineASR` |
| account | `apiKey` |
| 日志 | 不打印明文，不打印完整 header |

## 13. 错误处理

错误类型建议：

```swift
enum VolcengineASRError: Error {
    case missingAPIKey
    case missingResourceID
    case invalidEndpoint
    case connectionFailed(String)
    case protocolError(String)
    case serverError(code: Int, message: String)
    case timeout
    case cancelled
}
```

用户展示规则：

| 错误 | 展示 |
| --- | --- |
| `missingAPIKey` | 请先配置豆包 ASR API Key |
| `missingResourceID` | 请先配置豆包 ASR Resource ID |
| `invalidEndpoint` | 豆包 ASR Endpoint 无效 |
| `connectionFailed` | 连接豆包 ASR 失败 |
| `serverError` | 显示错误码和短消息 |
| `timeout` | 豆包 ASR 识别超时，请重试 |
| `cancelled` | 不展示 |

## 14. 超时策略

| 阶段 | 超时 |
| --- | --- |
| WebSocket 建连 | 10 秒 |
| 首个识别响应 | 15 秒 |
| stop 后最终响应 | 5 秒 |
| send 失败 | 立即失败 |

stop 后如果 5 秒内没有最终响应，使用最后一次非空文本作为最终文本；如果没有任何文本，则显示超时错误。

## 15. 日志与排错

建议新增 logger category：`VolcengineASR`。

允许记录：

1. request id 和 connect id。
2. WebSocket 连接成功或失败。
3. 服务端返回的 `X-Tt-Logid`，如果 URLSession 能从握手 response 中取得。
4. 错误码和短错误消息。
5. 发送音频总时长和总字节数。

禁止记录：

1. API Key。
2. 完整鉴权 header。
3. 原始音频数据。
4. 默认情况下不记录完整识别文本。

## 16. 权限影响

豆包 ASR 需要：

| 权限 | 是否需要 | 原因 |
| --- | --- | --- |
| Microphone | 是 | 录音 |
| Accessibility | 是 | 监听触发键和文本注入 |
| Speech Recognition | 否 | 不使用 `SFSpeechRecognizer` |

权限窗口需要根据当前引擎或说明文案调整，避免要求豆包用户必须授权 Apple Speech Recognition。

## 17. 实施计划

### Phase 1: 基础链路 ✅

1. ✅ 新增 settings model 和 Keychain helper。
2. ✅ 新增 `VolcengineASRProtocolCodec` 单元可测封包/解包逻辑。
3. ✅ 新增 `VolcengineAudioConverter`。
4. ✅ 新增 `VolcengineASRRecognizerController`。
5. ✅ 在 AppDelegate 中接入异步 stop 流程。

### Phase 2: UI 和产品化 ✅

1. ✅ 菜单新增识别引擎选项。
2. ✅ 设置窗口新增豆包配置项。
3. ✅ 首次启用隐私提示。
4. ✅ 本地化所有新增字符串。
5. ⏳ 更新 README 和隐私文档。

### Phase 3: 联调和打磨 🔧

1. ✅ 使用真实 API Key 验证 `bigmodel_async`。
2. ✅ 验证 no compression 可用。
3. 🔧 调整 chunk size、stop 等待时间和二遍识别配置。
4. 🔧 覆盖网络断开、鉴权失败、空音频、服务端错误帧。

## 18. 风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 服务端实际要求 gzip | 连接成功但识别失败 | 预留 compression 策略，必要时用 libz 实现 gzip |
| stop 需要异步等待最终结果 | 现有同步 stop 不适配 | AppDelegate 停止流程抽象为 completion |
| API Key 存储不安全 | 凭证泄露风险 | 新增 Keychain 存储 |
| 网络延迟或失败 | 用户无文本输出 | 使用最后非空结果，展示明确错误 |
| 云端上传影响隐私定位 | 用户误解产品默认隐私 | 默认不启用，首次启用强提示，更新隐私文档 |
| 语言映射不完全一致 | 某些语言识别质量不达预期 | 首版覆盖现有 8 个语言，设置中保留高级 language override 的可能 |

## 19. 测试策略

项目当前没有测试体系，建议至少新增轻量测试或可运行验证脚本覆盖纯逻辑模块：

| 模块 | 验证点 |
| --- | --- |
| Protocol codec | header 编码、UInt32 大端、错误帧解析、JSON payload 解析 |
| Audio converter | sample rate、channel、Int16 范围、chunk size |
| Settings | 默认值、缺失 key、Resource ID 读取 |
| Recognizer | cancel 后不回调、stop 超时使用最后文本 |

手动联调矩阵：

| 场景 | 期望 |
| --- | --- |
| 中文短句 | 实时返回并最终注入 |
| 英文短句 | 使用 `en-US` 返回英文 |
| 空录音 | 不注入或显示空音频错误 |
| 网络断开 | 展示错误并可重新录音 |
| API Key 错误 | 展示鉴权失败 |
| ESC 取消 | 无注入、无后续 UI 污染 |

## 20. 待确认技术问题

1. no compression 在 `bigmodel_async` 上是否稳定可用。
2. `URLSessionWebSocketTask` 是否能可靠读取握手响应 header 中的 `X-Tt-Logid`。
3. `zh-TW` 应使用 `traditional`、`tw` 还是 `hk`。
4. 是否要支持旧版控制台鉴权 header。
5. 是否在首版暴露 endpoint 高级配置，还是固定使用 `bigmodel_async`。

## 21. 可插拔架构设计

### 21.1 协议抽象 ✅

已实现通用云端 ASR 协议，所有厂商共享同一套状态机和音频缓冲逻辑：

```swift
protocol CloudASRProvider {
    var engineCode: String { get }
    var displayName: String { get }
    func validateCredentials() -> String?
    func createConnection() -> CloudASRConnection?
    func showSettings()
    var finalResultTimeout: Double { get }
}

protocol CloudASRConnection {
    var delegate: CloudASRConnectionDelegate? { get set }
    func resume()
    func sendAudioChunk(_ data: Data, isFinal: Bool)
    func cancel()
}
```

通用控制器 `CloudASRRecognizerController` 处理：
- 状态机（idle → connecting → streaming → finishing）
- 连接中音频缓冲，连接成功后 flush
- 最终结果超时
- 回调管理

### 21.2 各厂商适配器实现要点

| 厂商 | 适配器类 | 鉴权实现 | 协议特殊处理 | 状态 |
|---|---|---|---|---|
| 火山引擎 | `VolcengineASRProvider` + `VolcengineASRConnection` | HTTP Header | 自定义二进制帧编解码 | ✅ |
| 阿里云 | `AlibabaASRProvider` + `AlibabaASRConnection` | Token + URL 参数 | JSON 指令 + Binary 音频 | ❌ |
| 腾讯云 | `TencentASRProvider` + `TencentASRConnection` | URL HMAC-SHA1 签名 | Binary 音频 + JSON 结束 | ❌ |
| 讯飞 | `IFlytekASRProvider` + `IFlytekASRConnection` | URL HMAC-SHA1 签名 | Binary 音频 + JSON 结束 | ❌ |

### 21.3 阿里云接入技术细节 ❌

- **WebSocket URL**: `wss://nls-gateway-cn-shanghai.aliyuncs.com/ws/v1?token=<token>`
- **鉴权**: 先调阿里云 API 获取临时 Token，再拼到 URL
- **指令格式**: JSON Text Frame
  - `StartTranscription`: 开始识别，含 format、sample_rate、enable_intermediate_result 等参数
  - `StopTranscription`: 停止识别
- **音频**: Binary Frame，支持 PCM/WAV/OPUS/MP3 等
- **响应事件**:
  - `TranscriptionStarted`: 可以开始发送音频
  - `SentenceBegin`: 检测到一句话开始
  - `TranscriptionResultChanged`: 中间结果
  - `SentenceEnd`: 一句话结束，含最终结果
  - `TranscriptionCompleted`: 识别完成

### 21.4 腾讯云接入技术细节 ❌

- **WebSocket URL**: `wss://asr.cloud.tencent.com/asr/v2/<appid>?{params}`
- **鉴权**: 对所有参数按字典序排序 → HMAC-SHA1 → Base64 → URL 编码
- **音频**: Binary Frame，建议 200ms 发送 6400 字节（16kHz PCM）
- **结束信号**: Text Frame `{"type": "end"}`
- **响应**: JSON，`slice_type` 区分中间/最终结果
  - `0`: 一句话开始
  - `1`: 识别中（非稳态）
  - `2`: 识别结束（稳态）
- **特殊参数**: `noise_threshold`（噪音阈值）、`vad_silence_time`（断句阈值）

### 21.5 讯飞接入技术细节 ❌

- **WebSocket URL**: `wss://rtasr.xfyun.cn/v1/ws?{params}`
- **鉴权**: MD5(appid+ts) → HMAC-SHA1(apiKey) → Base64
- **音频**: Binary Frame，建议 40ms 发送 1280 字节
- **结束信号**: Binary Frame `{"end": true}`
- **响应**: JSON，`action` 字段区分类型
  - `started`: 握手成功
  - `result`: 识别结果，`data` 内嵌 JSON
  - `error`: 错误
- **结果格式**: 嵌套较深（`cn.st.rt[].ws[].cw[].w`），需要专门解析

### 21.6 通用设置存储 ✅

所有厂商共享同一套设置 key 模式：

| Key 模式 | 说明 |
|---|---|
| `<engine>ASREndpoint` | WebSocket URL |
| `<engine>ASRAPIKey` | API Key（存 Keychain） |
| `<engine>ASRResourceID` | 资源 ID 或 App ID |
| `<engine>ASREnablePunctuation` | 标点开关 |
| `<engine>ASREnableITN` | ITN 开关 |
| `<engine>ASRPrivacyAccepted` | 隐私确认 |

其中 `<engine>` 为引擎代码：`doubao`、`alibaba`、`tencent`、`iflytek`。

### 21.7 AppDelegate 集成 🔧

```swift
// 注册所有 provider
private var providers: [CloudASRProvider] = [
    VolcengineASRProvider(),
    // AlibabaASRProvider(),  // ❌ 未实现
    // TencentASRProvider(),  // ❌ 未实现
    // IFlytekASRProvider(),  // ❌ 未实现
]

// 根据用户选择创建控制器
private func makeCloudRecognizer(for engineCode: String) -> CloudASRRecognizerController? {
    guard let provider = providers.first(where: { $0.engineCode == engineCode }) else { return nil }
    return CloudASRRecognizerController(provider: provider)
}
```
