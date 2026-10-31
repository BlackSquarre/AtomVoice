import Accelerate
import AVFoundation
import Foundation
@testable import AtomVoiceCore

/// 直接驱动生产 AudioAnalyzer 和 WaveformEnvelope；保留旧算法作为离线对照，不创建窗口或采音。
enum WaveformResponseValidationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Production waveform analyzer matches approved 1024 point mapping") {
            let samples = voiceSamples(amplitude: 0.04, onset: 0.16, duration: 0.48, total: 0.96)
            let actual = try await productionBands(samples)
            let reference = SpectrumModel(candidate: true).analyze(samples)
            try expect(actual.count == reference.count)
            let error = zip(actual, reference).flatMap { pair in
                zip(pair.0, pair.1.levels).map { abs(Double($0) - $1) }
            }.max() ?? 0
            try expect(error < 0.000_01, "Production DSP should retain the approved 1024 point mapping")
            print(String(format: "WAVEFORM reference max_error=%.8f frames=%d", error, actual.count))
        }

        await runner.run("Production waveform preserves independent frequency bands") {
            let frequencies: [Double] = [187.5, 437.5, 1000, 2000, 3500]
            var oldDominant: [Int] = []
            var newDominant: [Int] = []
            var oldSelectivity: [Double] = []
            var newSelectivity: [Double] = []
            for (index, frequency) in frequencies.enumerated() {
                let samples = tone(frequency: frequency, amplitude: 0.08, count: 4096)
                let old = SpectrumModel(candidate: false).analyze(samples).last!.levels
                let new = try await productionBandFrames(samples).last!.levels
                oldDominant.append(dominant(old))
                newDominant.append(dominant(new))
                oldSelectivity.append(old[index] / max(0.000_01, old.enumerated().filter { $0.offset != index }.map(\.element).max()!))
                newSelectivity.append(new[index] / max(0.000_01, new.enumerated().filter { $0.offset != index }.map(\.element).max()!))
            }
            try expect(newDominant == Array(0..<5), "Each pure tone should drive its own bar most strongly")
            try expect(newSelectivity.min()! > 3)
            print("WAVEFORM tone_dominant legacy=\(oldDominant) production=\(newDominant)")
            print("WAVEFORM tone_selectivity legacy=\(formatted(oldSelectivity)) production=\(formatted(newSelectivity))")
        }

        await runner.run("Production waveform improves low level voice and release without delaying attack") {
            var report: [[String: Any]] = []
            for amplitude in [0.04, 0.006] {
                let onset = 0.256
                let offset = 0.640
                let samples = voiceSamples(amplitude: amplitude, onset: onset, duration: offset - onset, total: 1.6)
                let old = SpectrumModel(candidate: false).analyze(samples)
                let new = try await productionBandFrames(samples)
                let oldTrace = render(old, candidate: false, fps: 60, duration: 1.6)
                let newTrace = render(new, candidate: true, fps: 60, duration: 1.6)
                let oldMetrics = metrics(oldTrace, onset: onset, offset: offset)
                let newMetrics = metrics(newTrace, onset: onset, offset: offset)
                try expect(newMetrics.peak > oldMetrics.peak)
                try expect(newMetrics.rise90 <= oldMetrics.rise90 + 0.017)
                try expect(newMetrics.release10 < oldMetrics.release10)
                if amplitude < 0.01 { try expect(newMetrics.peak > oldMetrics.peak * 1.5) }
                try expect(newMetrics.release10 < 0.35)
                print(String(format: "WAVEFORM voice amplitude=%.3f legacy peak=%.3f rise90_ms=%.1f release10_ms=%.1f production1024 peak=%.3f rise90_ms=%.1f release10_ms=%.1f",
                             amplitude, oldMetrics.peak, oldMetrics.rise90 * 1000, oldMetrics.release10 * 1000,
                             newMetrics.peak, newMetrics.rise90 * 1000, newMetrics.release10 * 1000))
                report.append([
                    "amplitude": amplitude, "onset": onset, "offset": offset,
                    "variants": [
                        traceRecord(name: "legacy_1024", trace: oldTrace, metrics: oldMetrics),
                        traceRecord(name: "production_1024", trace: newTrace, metrics: newMetrics),
                    ],
                ])
            }
            try export(report, filename: "waveform-response-production.json")
        }

        await runner.run("Production waveform retains low frequency resolution") {
            var report: [[String: Any]] = []
            for frequency in [100.0, 125.0, 187.5, 218.75, 250.0, 281.25] {
                let samples = tone(frequency: frequency, amplitude: 0.04, count: 4096)
                let mapped1024 = try await productionBandFrames(samples).last!.levels
                let ratio1024 = mapped1024[0] / max(mapped1024[1], 0.000_01)
                try expect(mapped1024.allSatisfy { $0.isFinite })
                if frequency <= 218.75 {
                    try expect(dominant(mapped1024) == 0 && ratio1024 > 10)
                }
                if frequency >= 281.25 { try expect(dominant(mapped1024) == 1) }
                print(String(format: "WAVEFORM low_tone_hz=%.2f production_band0_vs_band1=%.3f", frequency, ratio1024))
                report.append(["frequency": frequency, "production1024": mapped1024])
            }
            try export(report, filename: "waveform-low-frequency-production.json")
        }

        await runner.run("Production waveform responds to short bursts without lighting silence") {
            let onset = 0.256
            let samples = voiceSamples(amplitude: 0.02, onset: onset, duration: 0.064, total: 0.8)
            let old = SpectrumModel(candidate: false).analyze(samples)
            let new = try await productionBandFrames(samples)
            let oldFirst = old.first { ($0.levels.max() ?? 0) > 0.01 }!.time - onset
            let newFirst = new.first { ($0.levels.max() ?? 0) > 0.01 }!.time - onset
            try expect(newFirst <= oldFirst)

            var random: UInt64 = 0x12345678
            let noise: [Float] = (0..<16_000).map { _ in
                random = random &* 6_364_136_223_846_793_005 &+ 1
                return Float(Double((random >> 32) & 0xffff) / 32767.5 - 1) * 0.0001
            }
            let silencePeak = try await productionBandFrames([Float](repeating: 0, count: 4096)).flatMap(\.levels).max()!
            let noisePeak = try await productionBandFrames(noise).flatMap(\.levels).max()!
            try expect(silencePeak == 0)
            try expect(noisePeak < 0.01)
            print(String(format: "WAVEFORM 64ms_burst first_DSP_ms legacy=%.1f production=%.1f silence_peak=%.4f quiet_noise_peak=%.4f",
                         oldFirst * 1000, newFirst * 1000, silencePeak, noisePeak))
        }

        await runner.run("Production waveform envelope stays consistent across display cadence") {
            let frames = stride(from: 0.032, through: 1.8, by: 0.032).map { time in
                BandFrame(time: time, levels: Array(repeating: time >= 0.256 && time < 0.768 ? 0.8 : 0, count: 5))
            }
            let old30 = metrics(render(frames, candidate: false, fps: 30, duration: 1.8), onset: 0.256, offset: 0.768)
            let old60 = metrics(render(frames, candidate: false, fps: 60, duration: 1.8), onset: 0.256, offset: 0.768)
            let new30 = metrics(render(frames, candidate: true, fps: 30, duration: 1.8), onset: 0.256, offset: 0.768)
            let new60 = metrics(render(frames, candidate: true, fps: 60, duration: 1.8), onset: 0.256, offset: 0.768)
            try expect(abs(new30.release10 - new60.release10) <= 1.0 / 30.0 + 0.0001)
            try expect(abs(old30.release10 - old60.release10) > abs(new30.release10 - new60.release10))
            print(String(format: "WAVEFORM cadence release10_ms legacy_30=%.1f legacy_60=%.1f production_30=%.1f production_60=%.1f",
                         old30.release10 * 1000, old60.release10 * 1000, new30.release10 * 1000, new60.release10 * 1000))
        }

        await runner.run("Production waveform envelope sanitizes samples and resets stale targets") {
            var envelope = WaveformEnvelope()
            envelope.updateBands([.nan, .infinity, -1, 3, 0.5])
            envelope.advance(by: 0.2)
            try expect(envelope.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            try expect(envelope.levels.prefix(3).allSatisfy { $0 == 0 })
            let previous = envelope.levels
            envelope.advance(by: .nan)
            envelope.advance(by: -1)
            try expect(envelope.levels == previous)
            envelope.reset()
            envelope.advance(by: 1)
            try expect(envelope.levels == [0, 0, 0, 0, 0])
        }

        await runner.run("Production waveform envelope is independent of callback count") {
            var once = WaveformEnvelope()
            var repeated = WaveformEnvelope()
            once.updateBands([0.6, 0.2, 0.9, 0.1, 0.4])
            for _ in 0..<20 { repeated.updateBands([0.6, 0.2, 0.9, 0.1, 0.4]) }
            once.advance(by: 1.0 / 60)
            repeated.advance(by: 1.0 / 60)
            try expect(once.levels == repeated.levels)
        }
    }

    private struct BandFrame { let time: Double; let levels: [Double] }
    private struct DisplayFrame { let time: Double; let level: Double }
    private struct Metrics { let peak: Double; let rise90: Double; let release10: Double }

    private static func productionBandFrames(_ samples: [Float]) async throws -> [BandFrame] {
        try await productionBands(samples).enumerated().map { index, values in
            BandFrame(time: Double(1024 + index * 512) / 16_000, levels: values.map(Double.init))
        }
    }

    private static func productionBands(_ samples: [Float]) async throws -> [[Float]] {
        let format = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        let analyzer = AudioAnalyzer()
        let expected = (samples.count - 1024) / 512 + 1
        defer { analyzer.onBands = nil }
        return await withCheckedContinuation { continuation in
            var result: [[Float]] = []
            analyzer.onBands = { bands in
                result.append(bands)
                if result.count == expected { continuation.resume(returning: result) }
            }
            analyzer.accept(buffer)
        }
    }

    /// 保留旧 DSP 对照与新映射参考；行为断言实际调用上面的生产分析器。
    private final class SpectrumModel {
        let candidate: Bool
        let size: Int
        let hop: Int
        let setup: FFTSetup
        var window: [Float]
        let ranges: [(Float, Float)] = [(100, 260), (260, 650), (650, 1500), (1500, 2800), (2800, 4200)]
        let floors: [Float] = [-50, -57, -61, -64, -66]
        let weights: [Float] = [0.25, 0.85, 1, 0.75, 0.20]
        let profiles: [Float] = [0.40, 0.68, 1, 0.68, 0.40]

        init(candidate: Bool) {
            self.candidate = candidate
            size = 1024
            hop = size / 2
            setup = vDSP_create_fftsetup(vDSP_Length(log2(Float(size))), FFTRadix(kFFTRadix2))!
            window = [Float](repeating: 0, count: size)
            vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func analyze(_ samples: [Float]) -> [BandFrame] {
            guard samples.count >= size else { return [] }
            return stride(from: 0, through: samples.count - size, by: hop).map { offset in
                BandFrame(time: Double(offset + size) / 16_000,
                          levels: levels(Array(samples[offset..<(offset + size)])).map(Double.init))
            }
        }

        func levels(_ samples: [Float]) -> [Float] {
            var windowed = [Float](repeating: 0, count: size)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
            var real = [Float](repeating: 0, count: size / 2)
            var imag = real
            var magnitudes = real
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    windowed.withUnsafeBytes { pointer in
                        pointer.withMemoryRebound(to: DSPComplex.self) { complex in
                            vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Float(size))), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
                }
            }
            var normalization = Float(size / 2)
            vDSP_vsdiv(magnitudes, 1, &normalization, &magnitudes, 1, vDSP_Length(size / 2))
            let spectral: [Float] = ranges.enumerated().map { index, range in
                let low = max(1, Int(range.0 / (16_000 / Float(size))))
                let high = min(size / 2 - 1, Int(range.1 / (16_000 / Float(size))))
                let bins = magnitudes[low...high]
                let energy = bins.reduce(0, +) / Float(bins.count) * 0.5 + bins.max()! * 0.5
                let db = 20 * log10(max(energy, 1e-7))
                return max(0, min(1, (db - floors[index]) / 40))
            }
            let presence = zip(spectral, weights).reduce(Float(0)) { $0 + $1.0 * $1.1 } / weights.reduce(0, +)
            if candidate {
                return spectral.map { local in
                    // 保留局部频段差异；少量全局成分让声音过窄时仍有整体响应。
                    let level = max(0, min(1, (0.82 * local + 0.18 * presence - 0.055) / 0.84))
                    return pow(level, 0.85)
                }
            }
            let voice = max(0, min(1, (presence - 0.055) / 0.84))
            return spectral.enumerated().map { index, value in
                max(0, min(1, voice * profiles[index] * (0.99 + value * 0.025)))
            }
        }
    }

    /// 只比较音频驱动的高度核，去掉待机正弦微动，避免把装饰动画当成声音响应。
    /// 旧核保留输入层和绘制层两次平滑；新核直接调用 WaveformView 使用的生产 envelope。
    private static func render(_ frames: [BandFrame], candidate: Bool, fps: Double, duration: Double) -> [DisplayFrame] {
        var levels = [Double](repeating: 0, count: 5)
        var targets = levels
        var heights = levels
        var envelope = WaveformEnvelope()
        var index = 0
        let dt = 1 / fps
        return (1...Int(duration * fps)).map { tick in
            let time = Double(tick) * dt
            while index < frames.count, frames[index].time <= time + 0.000_001 {
                targets = frames[index].levels
                if candidate {
                    envelope.updateBands(targets.map(Float.init))
                } else {
                    for band in 0..<5 {
                        var target = max(0, min(1, targets[band]))
                        if target < 0.015 { target = 0 }
                        else if !(levels[band] < 0.02 && target > levels[band]), abs(target - levels[band]) < 0.025 {
                            target = levels[band]
                        }
                        levels[band] += (target - levels[band]) * (target > levels[band] ? 0.86 : 0.12)
                    }
                }
                index += 1
            }
            if candidate {
                envelope.advance(by: dt)
                heights = envelope.levels
            } else {
                for band in 0..<5 {
                    heights[band] += (levels[band] - heights[band]) * (levels[band] > heights[band] ? 0.46 : 0.16)
                }
            }
            return DisplayFrame(time: time, level: heights.max()!)
        }
    }

    private static func metrics(_ frames: [DisplayFrame], onset: Double, offset: Double) -> Metrics {
        let peak = frames.filter { $0.time >= onset && $0.time <= offset }.map(\.level).max()!
        let rise = frames.first { $0.time >= onset && $0.level >= peak * 0.9 }!.time - onset
        let release = frames.first { $0.time >= offset && $0.level <= peak * 0.1 }?.time ?? frames.last!.time
        return Metrics(peak: peak, rise90: rise, release10: release - offset)
    }

    private static func voiceSamples(amplitude: Double, onset: Double, duration: Double, total: Double) -> [Float] {
        let components: [(Double, Double)] = [(187.5, 0.45), (437.5, 1), (1000, 0.7), (2000, 0.35), (3500, 0.18)]
        return (0..<Int(total * 16_000)).map { sample in
            let time = Double(sample) / 16_000
            guard time >= onset, time < onset + duration else { return 0 }
            return Float(components.reduce(0) { $0 + sin(2 * .pi * $1.0 * time) * $1.1 } * amplitude)
        }
    }

    private static func tone(frequency: Double, amplitude: Double, count: Int) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / 16_000) * amplitude) }
    }

    private static func dominant(_ values: [Double]) -> Int { values.indices.max { values[$0] < values[$1] }! }
    private static func formatted(_ values: [Double]) -> String { values.map { String(format: "%.3f", $0) }.joined(separator: ",") }

    private static func traceRecord(name: String, trace: [DisplayFrame], metrics: Metrics) -> [String: Any] {
        ["name": name, "peak": metrics.peak, "rise90_ms": metrics.rise90 * 1000,
         "release10_ms": metrics.release10 * 1000,
         "curve": trace.map { ["time": $0.time, "level": $0.level] }]
    }

    private static func export(_ cases: [[String: Any]], filename: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("localdoc/validation/2026-10-31-voice-feedback", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = [
            "scope": "Synthetic PCM through production AudioAnalyzer and production WaveformEnvelope, compared with a legacy reference. Excludes device capture, UI scheduling, drawing cost and decorative idle/sine motion; not an on-screen benchmark.",
            "cases": cases,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
