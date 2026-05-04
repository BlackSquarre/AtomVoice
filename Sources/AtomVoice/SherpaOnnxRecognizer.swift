import AVFoundation
import Cocoa
import Foundation
import SherpaOnnxShim

final class SherpaOnnxRecognizerController {
    static let modelName = "sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23-mobile"
    static let punctuationModelName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"

    private let queue = DispatchQueue(label: "com.atomvoice.sherpaOnnx")
    private var context: OpaquePointer?
    private var punctuationContext: OpaquePointer?
    private var onResult: ((String, Bool) -> Void)?
    private var lastText = ""
    private var finalText = ""

    deinit {
        if let punctuationContext {
            AtomVoiceSherpaPunctuationDestroy(punctuationContext)
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
        catch { print("[SherpaOnnx] 创建目录失败: \(error)") }
        NSWorkspace.shared.open(supportDirectory)
    }

    func start(onResult: @escaping (String, Bool) -> Void) -> String? {
        _ = stop()

        guard FileManager.default.fileExists(atPath: Self.runtimeLibDirectory.appendingPathComponent("libsherpa-onnx-c-api.dylib").path),
              FileManager.default.fileExists(atPath: Self.runtimeLibDirectory.appendingPathComponent("libonnxruntime.1.24.4.dylib").path)
        else {
            return loc("error.sherpaRuntimeMissing", Self.runtimeLibDirectory.path)
        }

        guard FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path),
              FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent("decoder-epoch-99-avg-1.onnx").path),
              FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path),
              FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent("tokens.txt").path)
        else {
            return loc("error.sherpaModelMissing", Self.modelDirectory.path)
        }

        var errorBuffer = [CChar](repeating: 0, count: 2048)
        let created = Self.runtimeLibDirectory.path.withCString { libDir in
            Self.modelDirectory.path.withCString { modelDir in
                errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                    AtomVoiceSherpaCreate(libDir, modelDir, errorPtr.baseAddress, Int32(errorPtr.count))
                }
            }
        }

        guard let created else {
            let detail = String(cString: errorBuffer)
            return loc("error.sherpaLoadFailed", detail.isEmpty ? "Unknown error" : detail)
        }

        context = created
        self.onResult = onResult
        lastText = ""
        finalText = ""
        return nil
    }

    func accept(buffer: AVAudioPCMBuffer) {
        guard let input = copyMonoSamples(from: buffer) else { return }

        queue.async { [weak self] in
            guard let self, let context = self.context else { return }

            let text: String? = input.samples.withUnsafeBufferPointer { samplesPtr in
                guard let baseAddress = samplesPtr.baseAddress else { return nil }
                guard AtomVoiceSherpaAcceptWaveform(context, input.sampleRate, baseAddress, Int32(samplesPtr.count)) != 0 else {
                    return nil
                }
                guard let cText = AtomVoiceSherpaGetResult(context) else { return nil }
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
            AtomVoiceSherpaDestroy(context)
            self.context = nil
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
            print("[SherpaOnnx] 标点模型或运行库不存在，跳过本地标点")
            return false
        }

        var errorBuffer = [CChar](repeating: 0, count: 2048)
        let created = Self.runtimeLibDirectory.path.withCString { libDir in
            Self.punctuationModelDirectory.path.withCString { modelDir in
                errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                    AtomVoiceSherpaPunctuationCreate(libDir, modelDir, errorPtr.baseAddress, Int32(errorPtr.count))
                }
            }
        }

        guard let created else {
            let detail = String(cString: errorBuffer)
            print("[SherpaOnnx] 标点模型加载失败: \(detail.isEmpty ? "Unknown error" : detail)")
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
