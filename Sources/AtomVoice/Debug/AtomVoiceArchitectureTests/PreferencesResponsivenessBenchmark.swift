import AppKit
import Foundation
@testable import AtomVoiceCore

/// 受控离线对比：真实 AppKit 表单 + 固定延迟凭据替身，以及临时目录资源检查。
/// 不读取用户密钥、模型或音频；不启动网络、权限和识别器。
enum PreferencesResponsivenessBenchmark {
    @MainActor
    static func run() async throws {
        let repetitions = 9
        var refreshReturn: [Double] = []
        var refreshComplete: [Double] = []
        var metadataRead: [Double] = []
        for iteration in 0..<repetitions {
            let settings = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: {
                Thread.sleep(forTimeInterval: 0.15)
                return .notFound
            }, writeKey: { _ in true }, deleteKey: { true })
            let editor = OpenAIASRSettingsEditor(settings: settings)
            #if RESPONSIVENESS_BASELINE
            let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: editor,
                                       allowsExternalActions: false, loadModels: { _ in [] })
            #else
            let tab = OpenAISettingsTab(textFieldDelegate: nil, editor: editor,
                                       allowsExternalActions: false, usesAsyncCredentials: true,
                                       loadModels: { _ in [] })
            #endif
            _ = tab.makeView(includeContext: false, allowsModelFetch: false)
            let started = ProcessInfo.processInfo.systemUptime
            tab.refresh()
            let returned = milliseconds(since: started)
            while editor.baseline == nil && milliseconds(since: started) < 5_000 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard editor.baseline != nil else { throw BenchmarkError.timedOut }
            if iteration > 0 {
                refreshReturn.append(returned)
                refreshComplete.append(milliseconds(since: started))
            }

            let entered = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let contended = OpenAIASRSettings(backend: InMemorySettingsBackend(), readKey: {
                entered.signal()
                Thread.sleep(forTimeInterval: 0.15)
                return .notFound
            }, writeKey: { _ in true }, deleteKey: { true })
            DispatchQueue.global(qos: .userInitiated).async {
                _ = contended.apiKeyReadResult()
                finished.signal()
            }
            guard entered.wait(timeout: .now() + 2) == .success else { throw BenchmarkError.timedOut }
            let readStarted = ProcessInfo.processInfo.systemUptime
            _ = try contended.configuration()
            if iteration > 0 { metadataRead.append(milliseconds(since: readStarted)) }
            // 不让本次凭据替身与下一轮测量重叠。
            while finished.wait(timeout: .now()) != .success {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        var scans: [[String: Any]] = []
        for cachedManifest in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtomVoice-responsive-fixture-\(UUID().uuidString)")
            let paths = SherpaResourcePaths(support: root)
            // 只清理本 benchmark 创建的随机临时目录。
            defer { try? FileManager.default.removeItem(at: root) }
            var presets: [SherpaModelPreset] = []
            for index in 0..<12 {
                let preset = SherpaModelPreset(id: "fixture-\(index)", language: "en-US", archiveURL: nil,
                                              archiveName: nil, extractedDirName: "fixture-\(index)", sizeMB: 0, isImported: true)
                let directory = paths.model(preset)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("extra"), withIntermediateDirectories: true)
                for name in ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"] {
                    try Data([1]).write(to: directory.appendingPathComponent(name))
                }
                for extra in 0..<32 { try Data([1]).write(to: directory.appendingPathComponent("extra/\(extra).txt")) }
                if cachedManifest {
                    try ModelManifest(encoder: "encoder.onnx", decoder: "decoder.onnx", joiner: "joiner.onnx", tokens: "tokens.txt").save(to: directory)
                }
                presets.append(preset)
            }
            var times: [Double] = []
            var inspectionCount = 0
            for iteration in 0..<repetitions {
                inspectionCount = 0
                let inspect: (URL) -> Bool = { url in
                    inspectionCount += 1
                    return ModelManifest.inspect(in: url) != nil
                }
                let started = ProcessInfo.processInfo.systemUptime
                #if RESPONSIVENESS_BASELINE
                // 修改前首次打开：makeView / refresh / refreshStatus 各重建一次，
                // 每次重建的 downloaded/pending 两个 filter 各检查一次。
                for _ in 0..<3 {
                    let downloaded = presets.filter { inspect(paths.model($0)) }
                    let pending = presets.filter { !inspect(paths.model($0)) }
                    guard downloaded.count == 12 && pending.isEmpty else { throw BenchmarkError.invalidFixture }
                }
                #else
                let inventory = SherpaModelInventory.scan(presets: presets, paths: paths, inspect: inspect)
                guard inventory.count == 12 && inventory.allSatisfy(\.isDownloaded) else { throw BenchmarkError.invalidFixture }
                #endif
                if iteration > 0 { times.append(milliseconds(since: started)) }
            }
            scans.append(["fixture": cachedManifest ? "valid_manifest" : "discover_36_files_per_model",
                          "models": 12, "inspections": inspectionCount, "scan_ms": statistics(times)])
        }
        #if RESPONSIVENESS_BASELINE
        let variant = "before"
        #else
        let variant = "after"
        #endif
        let report: [String: Any] = [
            "variant": variant, "samples": repetitions - 1, "warmups": 1,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Offline AppKit refresh with 150ms fake credential read; real temporary-file scan. Scan baseline reproduces the inspected call count, not full window timing. No real Keychain, audio, cloud ASR, model runtime, or screen-presentation timing.",
            "openai_refresh_main_thread_ms": statistics(refreshReturn),
            "openai_refresh_complete_ms": statistics(refreshComplete),
            "metadata_read_during_credentials_ms": statistics(metadataRead),
            "model_scans": scans,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func milliseconds(since start: Double) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
    private static func statistics(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        return ["median": (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2,
                "min": sorted.first!, "max": sorted.last!, "samples": values]
    }
    private enum BenchmarkError: Error { case timedOut, invalidFixture }
}
