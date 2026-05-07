# Sherpa 模型下载架构

## 概述

AtomVoice 使用 Sherpa-ONNX 作为本地离线语音识别引擎。模型下载采用**预设配置 + 动态下载**的方式，支持多语言、多尺寸模型，并针对中国大陆用户提供镜像站加速。

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    ASRSettingsWindow                         │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐        │
│  │ 豆包云端识别  │  │ Sherpa 本地  │  │ Apple 离线 │        │
│  └──────────────┘  └──────────────┘  └────────────┘        │
│                           │                                 │
│                    选择模型 / 触发下载                        │
└───────────────────────────┼─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    SherpaModelPreset                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  预设模型列表 (10个)                                  │   │
│  │  - zh-14M, zh-multi, zh-large, zh-xlarge            │   │
│  │  - bilingual-small, bilingual                        │   │
│  │  - en-20M, en-standard                               │   │
│  │  - korean, french                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│              获取下载URL（带镜像站支持）                      │
└───────────────────────────┼─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                   SherpaModelDownloader                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  下载组件:                                           │   │
│  │  1. Runtime dylib (sherpa-onnx 运行库)               │   │
│  │  2. ASR 模型 (用户选择的预设模型)                     │   │
│  │  3. 标点模型 (自动标点恢复)                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                    下载 → 解压 → 验证                        │
└───────────────────────────┼─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                SherpaOnnxRecognizerController                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  动态读取当前模型配置:                                │   │
│  │  - currentPreset: 当前选中的模型预设                  │   │
│  │  - modelName: 当前模型目录名                          │   │
│  │  - modelDirectory: 模型文件路径                       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. SherpaModelPreset.swift

**职责**: 定义模型配置结构和预设列表

```swift
struct SherpaModelPreset {
    let id: String                    // 模型唯一标识
    let language: String              // 语言代码
    let archiveURL: URL               // GitHub 下载地址
    let archiveName: String           // 压缩包文件名
    let extractedDirName: String      // 解压后目录名
    let encoderFile: String           // encoder 文件名
    let decoderFile: String           // decoder 文件名
    let joinerFile: String            // joiner 文件名
    let tokensFile: String            // tokens 文件名
    let sizeMB: Int                   // 模型体积
}
```

**预设模型列表**:

| ID | 语言 | 体积 | 说明 |
|----|------|------|------|
| `zh-14M` | zh-CN | 15MB | 轻量级，适合低配设备 |
| `zh-multi` | zh-CN | 73MB | 标准版，推荐 |
| `zh-large` | zh-CN | 160MB | 增强版 |
| `zh-xlarge` | zh-CN | 736MB | 旗舰版，准确率最高 |
| `bilingual-small` | bilingual | 80MB | 中英双语轻量版 |
| `bilingual` | bilingual | 260MB | 中英双语标准版 |
| `en-20M` | en-US | 20MB | 英文轻量版 |
| `en-standard` | en-US | 260MB | 英文标准版 |
| `korean` | ko-KR | 290MB | 韩语版 |
| `french` | fr-FR | 260MB | 法语版 |

**默认模型选择逻辑**:

```swift
static var defaultModelID: String {
    let memoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
    return memoryGB <= 8 ? "zh-14M" : "zh-multi"
}
```

### 2. SherpaModelDownloader.swift

**职责**: 管理模型下载、解压、验证

**下载流程**:

1. 检查哪些组件需要下载（运行库、ASR 模型、标点模型）
2. 依次下载每个组件
3. 解压到目标目录
4. 验证文件完整性

**下载组件**:

| 组件 | 说明 | 目标目录 |
|------|------|----------|
| Runtime | sherpa-onnx 运行库 (dylib) | `~/Library/Application Support/AtomVoice/SherpaOnnx/runtime/lib/` |
| ASR Model | 语音识别模型 | `~/Library/Application Support/AtomVoice/SherpaOnnx/models/{modelName}/` |
| Punctuation | 标点恢复模型 | `~/Library/Application Support/AtomVoice/SherpaOnnx/models/{punctuationModelName}/` |

### 3. ASRSettingsWindow.swift

**职责**: 提供统一的 ASR 设置界面

**标签页**:
- **豆包云端识别**: API Key、Resource ID、Endpoint 配置
- **Sherpa 本地识别**: 模型选择、下载状态、下载按钮
- **Apple 离线识别**: 离线模式开关、打开系统设置

## 镜像站支持

### 检测逻辑

```swift
static var needsMirror: Bool {
    // 1. 检查缓存
    if let cached = UserDefaults.standard.object(forKey: "sherpaMirrorCached") as? Bool {
        return cached
    }
    
    // 2. 尝试访问 GitHub（5秒超时）
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    let task = URLSession.shared.dataTask(with: URL(string: "https://github.com")!) { _, response, error in
        if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            success = true
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 5)
    task.cancel()
    
    // 3. 缓存结果
    let result = !success
    UserDefaults.standard.set(result, forKey: "sherpaMirrorCached")
    return result
}
```

### 镜像站 URL 转换

```swift
var downloadURL: URL {
    if SherpaModelPreset.needsMirror {
        return URL(string: "https://ghproxy.com/\(archiveURL.absoluteString)")!
    }
    return archiveURL
}
```

**支持的镜像站**:
- `ghproxy.com` — 速度较快，推荐
- `kkgithub.com` — 稳定性好
- `gitclone.com` — 备选

## 文件存储结构

```
~/Library/Application Support/AtomVoice/SherpaOnnx/
├── runtime/
│   └── lib/
│       ├── libsherpa-onnx-c-api.dylib
│       └── libonnxruntime.1.24.4.dylib
├── models/
│   ├── sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile/
│   │   ├── encoder-epoch-99-avg-1.int8.onnx
│   │   ├── decoder-epoch-99-avg-1.onnx
│   │   ├── joiner-epoch-99-avg-1.int8.onnx
│   │   └── tokens.txt
│   ├── sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12/
│   │   ├── encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx
│   │   ├── decoder-epoch-20-avg-1-chunk-16-left-128.onnx
│   │   ├── joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx
│   │   └── tokens.txt
│   └── sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/
│       └── model.int8.onnx
└── sherpa-onnx-v1.13.0-osx-universal2-shared-no-tts-lib/
    └── lib/
        └── ...（解压后的原始运行库）
```

## 用户交互流程

### 首次使用

1. 用户选择 Sherpa 本地识别引擎
2. 系统检测到模型未下载，弹出下载提示
3. 用户确认后开始下载
4. 下载完成后自动切换到新模型

### 切换模型

1. 用户打开"识别引擎设置"
2. 切换到"Sherpa 本地识别"标签页
3. 选择新的模型
4. 点击"下载选中模型"
5. 下载完成后保存选择

### 下载失败处理

1. 网络错误：提示用户检查网络连接
2. 解压失败：提示用户重新下载
3. 文件损坏：提示用户删除损坏文件并重新下载

## 本地化支持

所有用户可见的字符串都通过 `loc()` 函数获取，支持 8 种语言：

- English (en)
- 简体中文 (zh-Hans)
- 繁體中文 (zh-Hant)
- 日本語 (ja)
- 한국어 (ko)
- Español (es)
- Français (fr)
- Deutsch (de)

## 未来扩展

### 可能的改进

1. **断点续传**: 支持下载中断后继续下载
2. **并行下载**: 同时下载多个组件
3. **模型更新**: 检测模型版本并提示更新
4. **自定义模型**: 支持用户导入自己的模型
5. **模型删除**: 支持删除不需要的模型以释放空间

### 待支持的语言

目前 Sherpa-ONNX 没有以下语言的流式模型：

- 繁体中文 (zh-TW)
- 日语 (ja-JP)
- 西班牙语 (es-ES)
- 德语 (de-DE)

这些语言可以使用 Apple Speech 或豆包云端识别。
