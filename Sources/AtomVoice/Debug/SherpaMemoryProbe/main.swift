import AVFoundation
import Darwin
import Foundation
import MachO
import SherpaOnnxShim

#if DEBUG_BUILD

struct Options {
    var modelDir: String?
    var runtimeLibDir: String?
    var provider = "cpu"
    var audio: String?
    var modelID: String?
    var run = 1
}

struct ModelManifest {
    let encoder: String
    let decoder: String
    let joiner: String
    let tokens: String
}

struct MemorySnapshot: Codable {
    let footprintMB: Double
    let rssMB: Double
}

struct ProbeResult: Codable {
    let modelID: String
    let modelDir: String
    let modelSizeBytes: UInt64
    let modelSizeMB: Double
    let provider: String
    let run: Int
    let baselineFootprintMB: Double
    let afterLoadFootprintMB: Double
    let afterDecodeFootprintMB: Double?
    let loadDeltaMB: Double
    let decodeDeltaMB: Double?
    let peakFootprintMB: Double
    let baselineRSSMB: Double
    let afterLoadRSSMB: Double
    let afterDecodeRSSMB: Double?
    let loadMS: Double
    let decodeMS: Double?
    let audioFile: String?
    let audioFileSizeBytes: UInt64?
    let audioFileSizeMB: Double?
    let recognizedText: String
    let status: String
    let error: String
}

final class PeakSampler {
    private let lock = NSLock()
    private var running = false
    private(set) var peakFootprintMB = 0.0
    private var thread: Thread?

    func start() {
        lock.lock()
        running = true
        peakFootprintMB = currentMemory().footprintMB
        lock.unlock()

        let thread = Thread { [weak self] in
            while true {
                self?.lock.lock()
                let shouldRun = self?.running == true
                self?.lock.unlock()
                if !shouldRun { break }

                let footprint = currentMemory().footprintMB
                self?.lock.lock()
                if footprint > (self?.peakFootprintMB ?? 0) {
                    self?.peakFootprintMB = footprint
                }
                self?.lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> Double {
        lock.lock()
        running = false
        let peak = peakFootprintMB
        lock.unlock()
        return max(peak, currentMemory().footprintMB)
    }
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        switch key {
        case "--model-dir": options.modelDir = value()
        case "--runtime-lib-dir": options.runtimeLibDir = value()
        case "--provider": options.provider = value() ?? options.provider
        case "--audio": options.audio = value()
        case "--model-id": options.modelID = value()
        case "--run": options.run = Int(value() ?? "") ?? 1
        default: break
        }
    }
    return options
}

func currentMemory() -> MemorySnapshot {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return MemorySnapshot(footprintMB: 0, rssMB: 0) }
    return MemorySnapshot(
        footprintMB: Double(info.phys_footprint) / 1024.0 / 1024.0,
        rssMB: Double(info.resident_size) / 1024.0 / 1024.0
    )
}

func discoverManifest(in directory: URL) -> ModelManifest? {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }

    let regular = entries.filter { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }
    let onnx = regular.filter { $0.pathExtension.lowercased() == "onnx" && fileSize($0) > 0 }

    func pick(component: String, preferInt8: Bool) -> String? {
        let candidates = onnx.filter { $0.lastPathComponent.lowercased().contains(component) }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].lastPathComponent }
        let int8 = candidates.filter { $0.lastPathComponent.lowercased().contains("int8") }
        let nonInt8 = candidates.filter { !$0.lastPathComponent.lowercased().contains("int8") }
        return (preferInt8 ? (int8.first ?? nonInt8.first) : (nonInt8.first ?? int8.first))?.lastPathComponent
    }

    guard let encoder = pick(component: "encoder", preferInt8: true),
          let decoder = pick(component: "decoder", preferInt8: false),
          let joiner = pick(component: "joiner", preferInt8: true),
          let tokens = regular.first(where: { $0.lastPathComponent == "tokens.txt" && fileSize($0) > 0 })?.lastPathComponent
    else { return nil }

    return ModelManifest(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
}

func fileSize(_ url: URL) -> UInt64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber else { return 0 }
    return size.uint64Value
}

func directorySize(_ url: URL) -> UInt64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        total += UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

func loadAudioSamples(from url: URL) throws -> (samples: [Float], sampleRate: Int32) {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)!
    let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        throw NSError(domain: "SherpaMemoryProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output audio buffer"])
    }

    var didRead = false
    var conversionError: NSError?
    converter.convert(to: outputBuffer, error: &conversionError) { _, status in
        if didRead {
            status.pointee = .endOfStream
            return nil
        }
        didRead = true
        status.pointee = .haveData
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            status.pointee = .noDataNow
            return nil
        }
        do {
            try file.read(into: inputBuffer)
            return inputBuffer
        } catch {
            status.pointee = .noDataNow
            return nil
        }
    }
    if let conversionError { throw conversionError }

    guard let channel = outputBuffer.floatChannelData?[0] else { return ([], 16_000) }
    return (Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))), 16_000)
}

func emit(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func fail(options: Options, modelDir: String, modelSize: UInt64 = 0, audioSize: UInt64? = nil, message: String) -> Never {
    let memory = currentMemory()
    emit(ProbeResult(
        modelID: options.modelID ?? URL(fileURLWithPath: modelDir).lastPathComponent,
        modelDir: modelDir,
        modelSizeBytes: modelSize,
        modelSizeMB: Double(modelSize) / 1024.0 / 1024.0,
        provider: options.provider,
        run: options.run,
        baselineFootprintMB: memory.footprintMB,
        afterLoadFootprintMB: memory.footprintMB,
        afterDecodeFootprintMB: nil,
        loadDeltaMB: 0,
        decodeDeltaMB: nil,
        peakFootprintMB: memory.footprintMB,
        baselineRSSMB: memory.rssMB,
        afterLoadRSSMB: memory.rssMB,
        afterDecodeRSSMB: nil,
        loadMS: 0,
        decodeMS: nil,
        audioFile: options.audio,
        audioFileSizeBytes: audioSize,
        audioFileSizeMB: audioSize.map { Double($0) / 1024.0 / 1024.0 },
        recognizedText: "",
        status: "failed",
        error: message
    ))
    exit(1)
}

let options = parseOptions()
guard let modelDir = options.modelDir, let runtimeLibDir = options.runtimeLibDir else {
    fail(options: options, modelDir: options.modelDir ?? "", message: "Missing --model-dir or --runtime-lib-dir")
}

let modelURL = URL(fileURLWithPath: modelDir)
let modelSize = directorySize(modelURL)
let audioURL = options.audio.map { URL(fileURLWithPath: $0) }
let audioSize = audioURL.map(fileSize)

guard let manifest = discoverManifest(in: modelURL) else {
    fail(options: options, modelDir: modelDir, modelSize: modelSize, audioSize: audioSize, message: "Cannot discover encoder/decoder/joiner/tokens in model directory")
}

let baseline = currentMemory()
let sampler = PeakSampler()
sampler.start()
var errorBuffer = [CChar](repeating: 0, count: 4096)
let loadStart = DispatchTime.now().uptimeNanoseconds
let context = runtimeLibDir.withCString { libDir in
    modelDir.withCString { modelDirC in
        manifest.encoder.withCString { encoder in
            manifest.decoder.withCString { decoder in
                manifest.joiner.withCString { joiner in
                    manifest.tokens.withCString { tokens in
                        options.provider.withCString { provider in
                            errorBuffer.withUnsafeMutableBufferPointer { errorPtr in
                                AtomVoiceSherpaCreate(libDir, modelDirC, encoder, decoder, joiner, tokens, provider, errorPtr.baseAddress, Int32(errorPtr.count))
                            }
                        }
                    }
                }
            }
        }
    }
}
let loadEnd = DispatchTime.now().uptimeNanoseconds

guard let context else {
    let peak = sampler.stop()
    let after = currentMemory()
    let detail = String(cString: errorBuffer)
    emit(ProbeResult(
        modelID: options.modelID ?? modelURL.lastPathComponent,
        modelDir: modelDir,
        modelSizeBytes: modelSize,
        modelSizeMB: Double(modelSize) / 1024.0 / 1024.0,
        provider: options.provider,
        run: options.run,
        baselineFootprintMB: baseline.footprintMB,
        afterLoadFootprintMB: after.footprintMB,
        afterDecodeFootprintMB: nil,
        loadDeltaMB: after.footprintMB - baseline.footprintMB,
        decodeDeltaMB: nil,
        peakFootprintMB: peak,
        baselineRSSMB: baseline.rssMB,
        afterLoadRSSMB: after.rssMB,
        afterDecodeRSSMB: nil,
        loadMS: Double(loadEnd - loadStart) / 1_000_000.0,
        decodeMS: nil,
        audioFile: options.audio,
        audioFileSizeBytes: audioSize,
        audioFileSizeMB: audioSize.map { Double($0) / 1024.0 / 1024.0 },
        recognizedText: "",
        status: "failed",
        error: detail.isEmpty ? "AtomVoiceSherpaCreate failed" : detail
    ))
    exit(1)
}

Thread.sleep(forTimeInterval: 1.0)
let afterLoad = currentMemory()
var afterDecode: MemorySnapshot?
var decodeMS: Double?
var recognizedText = ""
var status = "ok"
var errorMessage = ""

if let audioURL {
    do {
        let audio = try loadAudioSamples(from: audioURL)
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let chunkSize = max(1, Int(audio.sampleRate) / 10)
        var index = 0
        while index < audio.samples.count {
            let end = min(index + chunkSize, audio.samples.count)
            let ok = audio.samples[index..<end].withContiguousStorageIfAvailable { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return AtomVoiceSherpaAcceptWaveform(context, audio.sampleRate, base, Int32(buffer.count))
            } ?? 0
            if ok == 0 {
                status = "failed"
                errorMessage = "AtomVoiceSherpaAcceptWaveform failed"
                break
            }
            index = end
        }
        if let cText = AtomVoiceSherpaFinish(context) {
            recognizedText = String(cString: cText)
            AtomVoiceSherpaFreeString(cText)
        }
        let decodeEnd = DispatchTime.now().uptimeNanoseconds
        decodeMS = Double(decodeEnd - decodeStart) / 1_000_000.0
        Thread.sleep(forTimeInterval: 0.5)
        afterDecode = currentMemory()
    } catch {
        status = "failed"
        errorMessage = "Audio decode failed: \(error.localizedDescription)"
        afterDecode = currentMemory()
    }
}

let peak = sampler.stop()
AtomVoiceSherpaDestroy(context)

emit(ProbeResult(
    modelID: options.modelID ?? modelURL.lastPathComponent,
    modelDir: modelDir,
    modelSizeBytes: modelSize,
    modelSizeMB: Double(modelSize) / 1024.0 / 1024.0,
    provider: options.provider,
    run: options.run,
    baselineFootprintMB: baseline.footprintMB,
    afterLoadFootprintMB: afterLoad.footprintMB,
    afterDecodeFootprintMB: afterDecode?.footprintMB,
    loadDeltaMB: afterLoad.footprintMB - baseline.footprintMB,
    decodeDeltaMB: afterDecode.map { $0.footprintMB - baseline.footprintMB },
    peakFootprintMB: peak,
    baselineRSSMB: baseline.rssMB,
    afterLoadRSSMB: afterLoad.rssMB,
    afterDecodeRSSMB: afterDecode?.rssMB,
    loadMS: Double(loadEnd - loadStart) / 1_000_000.0,
    decodeMS: decodeMS,
    audioFile: options.audio,
    audioFileSizeBytes: audioSize,
    audioFileSizeMB: audioSize.map { Double($0) / 1024.0 / 1024.0 },
    recognizedText: recognizedText,
    status: status,
    error: errorMessage
))

exit(status == "ok" ? 0 : 1)

#else

fputs("SherpaMemoryProbe is available only in DEBUG_BUILD.\n", stderr)
exit(2)

#endif
