import AVFoundation
import Cocoa
import Foundation
import SherpaOnnxShim

enum SherpaOnnxStartFailureKind {
    case missingRuntime
    case missingModel
    case invalidModel
    case loadFailed
}

final class SherpaOnnxRecognizerController {
    static let punctuationModelName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"

    /// 当前选中的模型预设（Currently selected model preset）
    static var currentPreset: SherpaModelPreset {
        SherpaModelPreset.current
    }

    /// 当前选择的计算后端（Current compute provider）
    static var provider: String {
        AppSettings.sherpaProvider
    }

    /// 当前模型目录名（Current model directory name）
    static var modelName: String {
        currentPreset.extractedDirName
    }

    private let queue = DispatchQueue(label: "com.atomvoice.sherpaOnnx")
    /// 串行化模型加载，防止快速点按 Fn 期间并发触发多次 AtomVoiceSherpaCreate 导致重复加载模型
    /// (Serializes model loading to prevent rapid Fn taps from triggering concurrent AtomVoiceSherpaCreate calls)
    private let loadingLock = NSLock()
    private var context: OpaquePointer?
    private var punctuationContext: OpaquePointer?
    private var onResult: ((String, Bool) -> Void)?
    private var lastText = ""
    private var finalText = ""
    private(set) var lastStartFailureKind: SherpaOnnxStartFailureKind?
    var isModelLoaded: Bool {
        queue.sync { context != nil }
    }

    var currentText: String {
        queue.sync { finalText }
    }

    deinit {
        if let context {
            AtomVoiceSherpaDestroy(context)
        }
        if let punctuationContext {
            AtomVoiceSherpaPunctuationDestroy(punctuationContext)
        }
    }

    /// 释放模型上下文以响应系统内存压力，下次录音时会重新加载（Release model context in response to system memory pressure, will reload on next recording）
    func releaseModels() {
        queue.sync {
            if let context {
                AtomVoiceSherpaDestroy(context)
                self.context = nil
            }
            if let punctuationContext {
                AtomVoiceSherpaPunctuationDestroy(punctuationContext)
                self.punctuationContext = nil
            }
            DebugLog.info("[SherpaOnnx] 已释放模型上下文")
        }
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AtomVoice/SherpaOnnx", isDirectory: true)
    }

    static var runtimeLibDirectory: URL {
        supportDirectory.appendingPathComponent("runtime/lib", isDirectory: true)
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var modelDirectory: URL {
        modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
    }

    static var punctuationModelDirectory: URL {
        modelsDirectory.appendingPathComponent(punctuationModelName, isDirectory: true)
    }

    static func createSupportDirectories() throws {
        try FileManager.default.createDirectory(at: runtimeLibDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    static func openSupportDirectory() {
        do { try createSupportDirectories() }
        catch { DebugLog.error("[SherpaOnnx] 创建目录失败: \(error)") }
        NSWorkspace.shared.open(supportDirectory)
    }

    func start(onResult: @escaping (String, Bool) -> Void) -> String? {
        // 已有识别器上下文时直接复用，不重新加载模型（Reuse existing recognizer context, don't reload model）
        if queue.sync(execute: { context != nil }) {
            queue.sync {
                self.onResult = onResult
                lastText = ""
                finalText = ""
            }
            return nil
        }

        // 串行化加载：若另一线程正在 Create，本调用阻塞等待；拿到锁后双重检查，命中即复用
        // (Serialize loading: block while another thread is creating; double-check after acquiring the lock)
        loadingLock.lock()
        defer { loadingLock.unlock() }

        if queue.sync(execute: { context != nil }) {
            queue.sync {
                self.onResult = onResult
                lastText = ""
                finalText = ""
            }
            return nil
        }

        lastStartFailureKind = nil

        let preset = Self.currentPreset
        guard let manifest = preset.resolveManifest() else {
            // 找不到 manifest 说明模型目录里没有可识别的 .onnx 文件 → 触发缺失模型路径
            // (No manifest means the model dir lacks recognizable .onnx files → treat as missing)
            lastStartFailureKind = .missingModel
            return loc("error.sherpaModelMissing", preset.modelDirectory.path)
        }
        DebugLog.info("[SherpaOnnx] 加载 \(preset.id): encoder=\(manifest.encoder) decoder=\(manifest.decoder) joiner=\(manifest.joiner) tokens=\(manifest.tokens) provider=\(Self.provider)")

        var errorBuffer = [CChar](repeating: 0, count: 2048)
        let providerStr = Self.provider
        let created = Self.runtimeLibDirectory.path.withCString { libDir in
            preset.modelDirectory.path.withCString { modelDir in
                manifest.encoder.withCString { encoder in
                    manifest.decoder.withCString { decoder in
                        manifest.joiner.withCString { joiner in
                            manifest.tokens.withCString { tokens in
                                providerStr.withCString { provider in
                                    errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                                        AtomVoiceSherpaCreate(libDir, modelDir, encoder, decoder, joiner, tokens,
                                                              provider, errorPtr.baseAddress, Int32(errorPtr.count))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard let created else {
            let detail = String(cString: errorBuffer)
            let message = detail.isEmpty ? "Unknown error" : detail
            let failureKind = Self.startFailureKind(for: message)
            #if DEBUG_BUILD
            DebugLog.debug("[SherpaOnnx] create failed kind=\(failureKind) provider=\(Self.provider) detail=\(message)")
            #endif
            lastStartFailureKind = failureKind
            switch failureKind {
            case .missingRuntime:
                return loc("error.sherpaRuntimeMissing", Self.runtimeLibDirectory.path)
            case .missingModel:
                return loc("error.sherpaModelMissing", Self.modelDirectory.path)
            case .invalidModel:
                return loc("error.sherpaLoadFailed", message)
            case .loadFailed:
                return loc("error.sherpaLoadFailed", message)
            }
        }

        queue.sync {
            context = created
            self.onResult = onResult
            lastText = ""
            finalText = ""
            // 标点模型与主识别器生命周期对齐：主模型加载完同步加载标点，避免 stop 后再触发 +200MB 的内存 spike。
            // 失败不致命（用户可能没下载标点模型），会回退到启发式标点。
            // (Load punctuation alongside main recognizer to avoid a +200MB spike at stop. Failure is OK — heuristic fallback kicks in.)
            _ = ensurePunctuationContext()
        }
        return nil
    }

    private static func startFailureKind(for detail: String) -> SherpaOnnxStartFailureKind {
        if detail.localizedCaseInsensitiveContains("runtime libraries not found") {
            return .missingRuntime
        }
        if detail.localizedCaseInsensitiveContains("model files not found") {
            return .missingModel
        }
        if detail.localizedCaseInsensitiveContains("Failed to create sherpa-onnx recognizer") ||
            detail.localizedCaseInsensitiveContains("Failed to create sherpa-onnx stream") {
            return .invalidModel
        }
        return .loadFailed
    }

    func accept(buffer: AVAudioPCMBuffer) {
        guard let input = copyMonoSamples(from: buffer) else { return }

        queue.async { [weak self] in
            guard let self, let context = self.context else { return }

            let text: String? = input.samples.withUnsafeBufferPointer { samplesPtr in
                guard let baseAddress = samplesPtr.baseAddress else { return nil }
                guard AtomVoiceSherpaAcceptWaveform(context, input.sampleRate, baseAddress, Int32(samplesPtr.count)) != 0 else {
                    #if DEBUG_BUILD
                    DebugLog.debug("[SherpaOnnx] accept waveform failed sampleRate=\(input.sampleRate) sampleCount=\(samplesPtr.count)")
                    #endif
                    return nil
                }
                guard let cText = AtomVoiceSherpaGetResult(context) else {
                    #if DEBUG_BUILD
                    DebugLog.debug("[SherpaOnnx] get result returned nil after accept")
                    #endif
                    return nil
                }
                defer { AtomVoiceSherpaFreeString(cText) }
                return String(cString: cText)
            }

            guard let text, !text.isEmpty, text != self.lastText else { return }
            self.lastText = text
            self.finalText = text
            DispatchQueue.main.async { [weak self] in
                self?.onResult?(text, false)
            }
        }
    }

    func stop() -> String {
        queue.sync {
            guard let context else { return finalText }
            if let cText = AtomVoiceSherpaFinish(context) {
                finalText = String(cString: cText)
                AtomVoiceSherpaFreeString(cText)
            }
            // 重置 stream 以备下次录音，但保留识别器上下文避免重复加载模型（Reset stream for next recording, but keep recognizer context to avoid reloading model）
            if AtomVoiceSherpaResetStream(context) == 0 {
                DebugLog.error("[SherpaOnnx] 重置 stream 失败，销毁上下文下次重建")
                AtomVoiceSherpaDestroy(context)
                self.context = nil
            }
            onResult = nil
            lastText = ""
            return finalText
        }
    }

    func punctuate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return queue.sync {
            guard ensurePunctuationContext() else { return nil }
            guard let punctuationContext else { return nil }

            return trimmed.withCString { input in
                guard let cText = AtomVoiceSherpaPunctuationAddPunct(punctuationContext, input) else {
                    #if DEBUG_BUILD
                    DebugLog.debug("[SherpaOnnx] punctuation add returned nil textLength=\(trimmed.count)")
                    #endif
                    return nil
                }
                defer { AtomVoiceSherpaFreeString(cText) }
                let output = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
                return output.isEmpty ? nil : output
            }
        }
    }

    private func ensurePunctuationContext() -> Bool {
        if punctuationContext != nil { return true }

        guard FileManager.default.fileExists(atPath: Self.runtimeLibDirectory.appendingPathComponent("libsherpa-onnx-c-api.dylib").path),
              FileManager.default.fileExists(atPath: Self.runtimeLibDirectory.appendingPathComponent("libonnxruntime.1.24.4.dylib").path),
              FileManager.default.fileExists(atPath: Self.punctuationModelDirectory.appendingPathComponent("model.int8.onnx").path)
        else {
            DebugLog.info("[SherpaOnnx] 标点模型或运行库不存在，跳过本地标点")
            return false
        }

        var errorBuffer = [CChar](repeating: 0, count: 2048)
        let providerStr = Self.provider
        let created = Self.runtimeLibDirectory.path.withCString { libDir in
            Self.punctuationModelDirectory.path.withCString { modelDir in
                providerStr.withCString { provider in
                    errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                        AtomVoiceSherpaPunctuationCreate(libDir, modelDir, provider, errorPtr.baseAddress, Int32(errorPtr.count))
                    }
                }
            }
        }

        guard let created else {
            let detail = String(cString: errorBuffer)
            DebugLog.error("[SherpaOnnx] 标点模型加载失败: \(detail.isEmpty ? "Unknown error" : detail)")
            return false
        }

        punctuationContext = created
        return true
    }

    private func copyMonoSamples(from buffer: AVAudioPCMBuffer) -> (sampleRate: Int32, samples: [Float])? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelCount = max(1, Int(buffer.format.channelCount))
        if channelCount == 1 {
            return (
                Int32(buffer.format.sampleRate),
                Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            )
        }

        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let source = channelData[channel]
            for i in 0..<frameCount {
                samples[i] += source[i] / Float(channelCount)
            }
        }
        return (Int32(buffer.format.sampleRate), samples)
    }
}
