import Foundation

#if DEBUG_BUILD

struct Options {
    var modelsDir = "\(NSHomeDirectory())/Library/Application Support/AtomVoice/SherpaOnnx/models"
    var runtimeLibDir = "\(NSHomeDirectory())/Library/Application Support/AtomVoice/SherpaOnnx/runtime/lib"
    var providers = ["cpu", "coreml"]
    var runs = 3
    var audio: String?
    var outputDir = "dist"
    var probePath: String?
}

struct RunMetadata {
    let timestamp: Date
    let timestampForFile: String
    let timestampDisplay: String
    let runtimeVersion: String
}

struct ModelManifest {
    enum Family {
        case onlineTransducer
        case onlineParaformer
    }

    let family: Family
    let encoder: String
    let decoder: String
    let joiner: String?
    let tokens: String
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

struct ModelCandidate {
    let id: String
    let dir: URL
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        switch key {
        case "--models-dir": options.modelsDir = value() ?? options.modelsDir
        case "--runtime-lib-dir": options.runtimeLibDir = value() ?? options.runtimeLibDir
        case "--providers":
            options.providers = (value() ?? "cpu,coreml")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case "--runs": options.runs = max(1, Int(value() ?? "") ?? options.runs)
        case "--audio": options.audio = value()
        case "--output-dir": options.outputDir = value() ?? options.outputDir
        case "--probe": options.probePath = value()
        default: break
        }
    }
    return options
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

func discoverManifest(in directory: URL) -> ModelManifest? {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    let regular = enumerator.compactMap { item -> URL? in
        guard let url = item as? URL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }
    let onnx = regular.filter { $0.pathExtension.lowercased() == "onnx" && fileSize($0) > 0 }

    func relativePath(_ url: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    let isInt8: (URL) -> Bool = { $0.lastPathComponent.lowercased().contains("int8") }

    func pick(component: String, preferInt8: Bool) -> String? {
        let candidates = onnx.filter { $0.lastPathComponent.lowercased().contains(component) }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return relativePath(candidates[0]) }
        let int8 = candidates.filter(isInt8)
        let nonInt8 = candidates.filter { !isInt8($0) }
        return preferInt8
            ? (int8.first ?? nonInt8.first).map(relativePath)
            : (nonInt8.first ?? int8.first).map(relativePath)
    }

    guard let tokens = regular.first(where: { $0.lastPathComponent == "tokens.txt" && fileSize($0) > 0 }).map(relativePath) else {
        return nil
    }

    if let encoder = pick(component: "encoder", preferInt8: true),
       let decoder = pick(component: "decoder", preferInt8: false),
       let joiner = pick(component: "joiner", preferInt8: true) {
        return ModelManifest(
            family: .onlineTransducer,
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
            tokens: tokens
        )
    }

    func pickParaformerPair() -> (String, String)? {
        let encoders = onnx.filter { $0.lastPathComponent.lowercased().contains("encoder") }
        let decoders = onnx.filter { $0.lastPathComponent.lowercased().contains("decoder") }
        guard !encoders.isEmpty, !decoders.isEmpty else { return nil }

        let int8Encoders = encoders.filter(isInt8)
        let plainEncoders = encoders.filter { !isInt8($0) }
        let int8Decoders = decoders.filter(isInt8)
        let plainDecoders = decoders.filter { !isInt8($0) }

        if let encoder = int8Encoders.first, let decoder = int8Decoders.first {
            return (relativePath(encoder), relativePath(decoder))
        }
        if let encoder = plainEncoders.first, let decoder = plainDecoders.first {
            return (relativePath(encoder), relativePath(decoder))
        }

        let selectedEncoder = int8Encoders.first ?? plainEncoders.first ?? encoders[0]
        let selectedDecoder = int8Decoders.first ?? plainDecoders.first ?? decoders[0]
        return (relativePath(selectedEncoder), relativePath(selectedDecoder))
    }

    if let (encoder, decoder) = pickParaformerPair() {
        return ModelManifest(
            family: .onlineParaformer,
            encoder: encoder,
            decoder: decoder,
            joiner: nil,
            tokens: tokens
        )
    }

    return nil
}

func discoverModels(in modelsDir: String) -> [ModelCandidate] {
    let root = URL(fileURLWithPath: modelsDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.compactMap { url in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        guard !url.lastPathComponent.lowercased().contains("punct") else { return nil }
        guard discoverManifest(in: url) != nil else { return nil }
        return ModelCandidate(id: url.lastPathComponent, dir: url)
    }.sorted { $0.id < $1.id }
}

func defaultProbePath() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.deletingLastPathComponent().appendingPathComponent("SherpaMemoryProbe").path
}

func runProbe(probePath: String, model: ModelCandidate, provider: String, run: Int, options: Options) -> ProbeResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: probePath)
    var arguments = [
        "--model-dir", model.dir.path,
        "--runtime-lib-dir", options.runtimeLibDir,
        "--provider", provider,
        "--model-id", model.id,
        "--run", String(run),
    ]
    if let audio = options.audio {
        arguments += ["--audio", audio]
    }
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Failed to run probe for \(model.id) provider=\(provider): \(error.localizedDescription)\n", stderr)
        return nil
    }

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let jsonLine = output.split(separator: "\n").last.map(String.init) ?? ""
    guard let data = jsonLine.data(using: .utf8), let result = try? JSONDecoder().decode(ProbeResult.self, from: data) else {
        fputs("Probe produced no JSON for \(model.id) provider=\(provider). stderr: \(errorText)\n", stderr)
        return nil
    }
    return result
}

func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

func format(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.1f", value)
}

func formatMS(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.0f", value)
}

func makeRunMetadata(runtimeLibDir: String) -> RunMetadata {
    let now = Date()
    let fileFormatter = DateFormatter()
    fileFormatter.locale = Locale(identifier: "en_US_POSIX")
    fileFormatter.timeZone = TimeZone.current
    fileFormatter.dateFormat = "yyyyMMdd-HHmmss"

    let displayFormatter = DateFormatter()
    displayFormatter.locale = Locale(identifier: "en_US_POSIX")
    displayFormatter.timeZone = TimeZone.current
    displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"

    let runtimeDir = URL(fileURLWithPath: runtimeLibDir).deletingLastPathComponent()
    let versionURL = runtimeDir.appendingPathComponent("version.txt")
    let version = (try? String(contentsOf: versionURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return RunMetadata(
        timestamp: now,
        timestampForFile: fileFormatter.string(from: now),
        timestampDisplay: displayFormatter.string(from: now),
        runtimeVersion: (version?.isEmpty == false ? version! : "unknown")
    )
}

func writeCSV(results: [ProbeResult], metadata: RunMetadata, to url: URL) throws {
    let header = [
        "run_timestamp", "runtime_version", "model_id", "model_dir", "model_size_bytes", "model_size_mb", "provider", "run",
        "baseline_footprint_mb", "after_load_footprint_mb", "after_decode_footprint_mb",
        "load_delta_mb", "decode_delta_mb", "peak_footprint_mb",
        "baseline_rss_mb", "after_load_rss_mb", "after_decode_rss_mb",
        "load_ms", "decode_ms", "audio_file", "audio_file_size_bytes", "audio_file_size_mb",
        "recognized_text", "status", "error",
    ]
    var lines = [header.joined(separator: ",")]
    for r in results {
        let row = [
            csvEscape(metadata.timestampDisplay),
            csvEscape(metadata.runtimeVersion),
            csvEscape(r.modelID),
            csvEscape(r.modelDir),
            String(r.modelSizeBytes),
            format(r.modelSizeMB),
            csvEscape(r.provider),
            String(r.run),
            format(r.baselineFootprintMB),
            format(r.afterLoadFootprintMB),
            format(r.afterDecodeFootprintMB),
            format(r.loadDeltaMB),
            format(r.decodeDeltaMB),
            format(r.peakFootprintMB),
            format(r.baselineRSSMB),
            format(r.afterLoadRSSMB),
            format(r.afterDecodeRSSMB),
            formatMS(r.loadMS),
            formatMS(r.decodeMS),
            csvEscape(r.audioFile ?? ""),
            r.audioFileSizeBytes.map(String.init) ?? "",
            format(r.audioFileSizeMB),
            csvEscape(r.recognizedText),
            csvEscape(r.status),
            csvEscape(r.error),
        ]
        lines.append(row.joined(separator: ","))
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

func medianResult(_ results: [ProbeResult]) -> ProbeResult? {
    guard !results.isEmpty else { return nil }
    let sorted = results.sorted { lhs, rhs in
        let l = lhs.decodeDeltaMB ?? lhs.loadDeltaMB
        let r = rhs.decodeDeltaMB ?? rhs.loadDeltaMB
        return l < r
    }
    return sorted[sorted.count / 2]
}

func writeMarkdown(results: [ProbeResult], options: Options, metadata: RunMetadata, to url: URL) throws {
    var markdown: [String] = []
    markdown.append("# Sherpa Model Memory Benchmark")
    markdown.append("")
    markdown.append("- Run Timestamp: `\(metadata.timestampDisplay)`")
    markdown.append("- Runtime Version: `\(metadata.runtimeVersion)`")
    markdown.append("- Models Dir: `\(options.modelsDir)`")
    markdown.append("- Runtime Lib Dir: `\(options.runtimeLibDir)`")
    markdown.append("- Providers: `\(options.providers.joined(separator: ","))`")
    markdown.append("- Runs: `\(options.runs)`")
    if let audio = options.audio {
        let size = Double(fileSize(URL(fileURLWithPath: audio))) / 1024.0 / 1024.0
        markdown.append("- Audio: `\(audio)` (\(format(size)) MB)")
    }
    let runtimeSize = Double(directorySize(URL(fileURLWithPath: options.runtimeLibDir))) / 1024.0 / 1024.0
    markdown.append("- Runtime Size: \(format(runtimeSize)) MB")
    markdown.append("")
    markdown.append("| Model | Provider | Model Size | Load Δ | Decode Δ | Peak | Load Time | Decode Time | Text | Status |")
    markdown.append("|---|---|---:|---:|---:|---:|---:|---:|---|---|")

    let groups = Dictionary(grouping: results) { "\($0.modelID)\u{1f}\($0.provider)" }
    let medians = groups.values.compactMap(medianResult).sorted {
        if $0.modelID == $1.modelID { return $0.provider < $1.provider }
        return $0.modelID < $1.modelID
    }
    for r in medians {
        let text = r.recognizedText.replacingOccurrences(of: "|", with: "\\|")
        let status = r.status == "ok" ? "ok" : "failed: \(r.error.replacingOccurrences(of: "|", with: "\\|"))"
        markdown.append("| \(r.modelID) | \(r.provider) | \(format(r.modelSizeMB)) MB | \(format(r.loadDeltaMB)) MB | \(format(r.decodeDeltaMB)) MB | \(format(r.peakFootprintMB)) MB | \(formatMS(r.loadMS)) ms | \(formatMS(r.decodeMS)) ms | \(text) | \(status) |")
    }
    markdown.append("")
    markdown.append("Raw per-run results are in `\(url.deletingPathExtension().lastPathComponent).csv`.")
    try markdown.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

let options = parseOptions()
let probePath = options.probePath ?? defaultProbePath()
guard FileManager.default.isExecutableFile(atPath: probePath) else {
    fputs("Probe executable not found: \(probePath)\n", stderr)
    exit(2)
}

let models = discoverModels(in: options.modelsDir)
guard !models.isEmpty else {
    fputs("No Sherpa ASR models found in \(options.modelsDir)\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(atPath: options.outputDir, withIntermediateDirectories: true)
let metadata = makeRunMetadata(runtimeLibDir: options.runtimeLibDir)
var results: [ProbeResult] = []
for model in models {
    for provider in options.providers {
        for run in 1...options.runs {
            print("Testing \(model.id) provider=\(provider) run=\(run)/\(options.runs)")
            if let result = runProbe(probePath: probePath, model: model, provider: provider, run: run, options: options) {
                results.append(result)
            }
        }
    }
}

let outputDir = URL(fileURLWithPath: options.outputDir)
let baseName = "sherpa-memory-report-\(metadata.timestampForFile)"
let csvURL = outputDir.appendingPathComponent("\(baseName).csv")
let markdownURL = outputDir.appendingPathComponent("\(baseName).md")
try writeCSV(results: results, metadata: metadata, to: csvURL)
try writeMarkdown(results: results, options: options, metadata: metadata, to: markdownURL)
print("CSV: \(csvURL.path)")
print("Markdown: \(markdownURL.path)")

#else

fputs("SherpaMemoryBenchmark is available only in DEBUG_BUILD.\n", stderr)
exit(2)

#endif
