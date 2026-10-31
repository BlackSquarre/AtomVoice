import Foundation

// 仅供离线对照的实验，既不调用生产监控器，也不修改设置或连接音频设备。
// 合成信号不是用户录音；周期性分数不是经过标定的语音概率。
private enum EndpointExperiment {
    static let sampleRate = 16_000.0
    static let frameDuration = 0.04
    static let frameCount = 640
    static let silenceDuration = 3.0

    struct Features {
        let rms: Double
        let decibels: Double
        let periodicity: Double
        let zeroCrossingRate: Double
        let crest: Double
    }

    static func features(_ samples: [Double]) -> Features {
        var power = 0.0
        var peak = 0.0
        var crossings = 0
        var reduced: [Double] = []
        reduced.reserveCapacity(samples.count / 4)
        var sum = 0.0
        for i in samples.indices {
            let value = samples[i]
            power += value * value
            peak = max(peak, abs(value))
            if i > 0, (value >= 0) != (samples[i - 1] >= 0) { crossings += 1 }
            sum += value
            if i % 4 == 3 {
                reduced.append(sum / 4)
                sum = 0
            }
        }
        let rms = sqrt(power / Double(max(1, samples.count)))
        var periodicity = 0.0
        // 四点平均只服务此实验的粗略特征降采样，不是完整抗混叠滤波器。
        // 4 kHz 下搜索约 80–400 Hz；O(帧样本数 × lag数)，不应直接搬到音频 tap。
        if rms > 1e-8, reduced.count > 50 {
            for lag in 10...50 {
                var dot = 0.0
                var left = 0.0
                var right = 0.0
                for i in lag..<reduced.count {
                    let a = reduced[i]
                    let b = reduced[i - lag]
                    dot += a * b
                    left += a * a
                    right += b * b
                }
                periodicity = max(periodicity, dot / max(1e-12, sqrt(left * right)))
            }
        }
        return Features(rms: rms, decibels: 20 * log10(max(rms, 1e-8)),
                        periodicity: periodicity,
                        zeroCrossingRate: Double(crossings) / Double(max(1, samples.count)),
                        crest: peak / max(rms, 1e-8))
    }

    struct TextEvent {
        let arrival: Double
        let audioEnd: Double?
        let text: String
        var generation = 1
    }

    struct TextBaseline {
        var lastText = ""
        var lastChange = 0.0
        var nextTick = 0.1
        var stop: Double?

        mutating func observe(_ event: TextEvent) {
            guard stop == nil, event.text != lastText else { return }
            lastText = event.text
            lastChange = event.arrival
        }

        mutating func advance(to time: Double) {
            guard stop == nil, time + 1e-9 >= nextTick else { return }
            nextTick += 0.1
            if time > 0.5, time - lastChange + 1e-9 >= silenceDuration { stop = time }
        }
    }

    struct LegacyBaseline {
        var history: [Double] = []
        var quiet = 0.0
        var steady = 0.0
        var stop: Double?

        mutating func advance(_ feature: Features, time: Double) {
            guard stop == nil, time > 0.5 else { return }
            history.append(feature.rms)
            if history.count > 30 { history.removeFirst() }
            let mean = history.reduce(0, +) / Double(history.count)
            let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count)
            let steadyNoise = history.count == 30 && feature.rms > 0.005 && variance < 0.001
            if feature.decibels < -40 {
                quiet += frameDuration
                steady = 0
            } else if steadyNoise {
                quiet = 0
                steady += frameDuration
            } else {
                quiet = 0
                steady = 0
            }
            if max(quiet, steady) + 1e-9 >= silenceDuration { stop = time }
        }
    }

    struct Candidate {
        struct Token { let generation: Int; let revision: Int }
        var generation = 1
        var allowUntimedGrowthHeartbeat = false
        var revision = 0
        var lastActivity = 0.0
        var lastText = ""
        var noiseFloor = -70.0
        var maxNoiseFloor = -70.0
        var voicedRun = 0.0
        var unanchoredGraceUsed = false
        var deadlineExtension = 0.0
        var stop: Double?

        mutating func observe(_ feature: Features, time: Double) {
            guard stop == nil else { return }
            let voicedShape = feature.periodicity >= 0.72 && feature.zeroCrossingRate < 0.20 && feature.crest < 4
            // 可能是长元音时冻结噪声学习，不能把平稳发声慢慢吞进噪声底。
            // 同样会冻结周期性机器噪声，这是需要报告的失败边界。
            if !voicedShape {
                noiseFloor += 0.12 * (max(-80, feature.decibels) - noiseFloor)
                maxNoiseFloor = max(maxNoiseFloor, noiseFloor)
            }
            let voiced = voicedShape && feature.decibels >= max(-60, noiseFloor + 8)
            voicedRun = voiced ? voicedRun + frameDuration : 0
            if voicedRun >= 0.08 { noteActivity(at: time) }
        }

        mutating func observe(_ event: TextEvent) {
            guard stop == nil, event.generation == generation, event.text != lastText else { return }
            let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
            func normalized(_ text: String) -> String {
                String(String.UnicodeScalarView(text.unicodeScalars.filter { !ignored.contains($0) }))
            }
            let previous = normalized(lastText)
            let current = normalized(event.text)
            lastText = event.text
            if let audioEnd = event.audioEnd {
                guard audioEnd >= 0, audioEnd <= event.arrival else { return }
                noteActivity(at: audioEnd)
            } else if current.hasPrefix(previous), current.count > previous.count {
                if allowUntimedGrowthHeartbeat {
                    // 候选二兼容当前回调：明确新增文字仍续录，但积压旧文字也可能延迟结束。
                    noteActivity(at: event.arrival)
                } else if !unanchoredGraceUsed {
                    // 候选一无音频时间戳时同一静默窗口最多给 0.6 秒。
                    unanchoredGraceUsed = true
                    deadlineExtension = 0.6
                    revision += 1
                }
            }
        }

        mutating func noteActivity(at time: Double) {
            guard time > lastActivity else { return }
            lastActivity = time
            unanchoredGraceUsed = false
            deadlineExtension = 0
            revision += 1
        }

        func proposal(at time: Double) -> Token? {
            guard stop == nil, time > 0.5,
                  time - lastActivity + 1e-9 >= silenceDuration + deadlineExtension else { return nil }
            return Token(generation: generation, revision: revision)
        }

        mutating func commit(_ token: Token, at time: Double) {
            guard token.generation == generation, token.revision == revision, proposal(at: time) != nil else { return }
            stop = time
        }
    }

    struct Scenario {
        let name: String
        var voice: [ClosedRange<Double>] = []
        var voiceAmplitude = 0.04
        var noiseAmplitude = 0.0
        var keyboard = false
        var tonalMachine = false
        var unvoiced = false
        var text: [TextEvent] = []
        let desiredStop: Double
        var knownBoundary = false
    }

    struct Result {
        let scenario: Scenario
        let text: Double?
        let legacy: Double?
        let candidate: Double?
        let practical: Double?
        let noiseFloor: Double
    }

    static func pcm(_ scenario: Scenario, duration: Double = 12) -> [[Double]] {
        var seed: UInt64 = 0x41544f4d564f4943
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / 4_503_599_627_370_496.0 - 1
        }
        return (0..<Int((duration / frameDuration).rounded())).map { frame in
            (0..<frameCount).map { sample in
                let time = Double(frame * frameCount + sample) / sampleRate
                let random = noise()
                var value = random * scenario.noiseAmplitude
                let humanVoice = scenario.voice.contains { $0.contains(time) }
                if humanVoice || scenario.tonalMachine {
                    if scenario.unvoiced {
                        value += random * scenario.voiceAmplitude * (0.7 + 0.3 * sin(2 * .pi * 3 * time))
                    } else {
                        let phase = 2 * Double.pi * 160 * time
                        value += scenario.voiceAmplitude * (sin(phase) + 0.45 * sin(2 * phase) + 0.2 * sin(3 * phase))
                    }
                }
                if scenario.keyboard, frame % 10 == 0, sample < 24 {
                    value += random * 0.9
                }
                return value
            }
        }
    }

    static func evaluate(_ scenario: Scenario) -> Result {
        let audio = pcm(scenario)
        var text = TextBaseline()
        var legacy = LegacyBaseline()
        var candidate = Candidate()
        var practical = Candidate(allowUntimedGrowthHeartbeat: true)
        var eventIndex = 0
        for (index, samples) in audio.enumerated() {
            let time = Double(index + 1) * frameDuration
            while eventIndex < scenario.text.count, scenario.text[eventIndex].arrival <= time + 1e-9 {
                let event = scenario.text[eventIndex]
                text.observe(event)
                candidate.observe(event)
                practical.observe(event)
                eventIndex += 1
            }
            let feature = features(samples)
            candidate.observe(feature, time: time)
            practical.observe(feature, time: time)
            if let token = candidate.proposal(at: time) { candidate.commit(token, at: time) }
            if let token = practical.proposal(at: time) { practical.commit(token, at: time) }
            text.advance(to: time)
            legacy.advance(feature, time: time)
        }
        return Result(scenario: scenario, text: text.stop, legacy: legacy.stop,
                      candidate: candidate.stop, practical: practical.stop, noiseFloor: candidate.maxNoiseFloor)
    }

    static var scenarios: [Scenario] {
        [
            Scenario(name: "filler_without_text", voice: [0...1, 3.2...3.6, 5.6...6, 8...8.4],
                     text: [TextEvent(arrival: 0.8, audioEnd: 0.8, text: "a")], desiredStop: 11.4),
            Scenario(name: "steady_vowel", voice: [0...8], desiredStop: 11),
            Scenario(name: "soft_voiced", voice: [0...8], voiceAmplitude: 0.004, desiredStop: 11),
            Scenario(name: "broadband_fan", noiseAmplitude: 0.04, desiredStop: 3),
            Scenario(name: "keyboard_clicks", keyboard: true, desiredStop: 3),
            Scenario(name: "silent_thinking", voice: [0...1, 7...8], desiredStop: 11, knownBoundary: true),
            Scenario(name: "tonal_machine_same_as_voice", tonalMachine: true, desiredStop: 3, knownBoundary: true),
            Scenario(name: "very_quiet_voiced", voice: [0...8], voiceAmplitude: 0.0003, desiredStop: 11, knownBoundary: true),
            Scenario(name: "unvoiced_without_text", voice: [0...8], unvoiced: true, desiredStop: 11, knownBoundary: true),
            // 当前生产回调没有 audioEnd；有效新文本持续到达时不能隐瞒候选策略的误停。
            Scenario(name: "unvoiced_live_untimed_text", voice: [0...8], unvoiced: true,
                     text: (1...10).map { TextEvent(arrival: Double($0) * 0.8, audioEnd: nil,
                                                  text: String(repeating: "a", count: $0)) },
                     desiredStop: 11, knownBoundary: true),
            Scenario(name: "delayed_timestamped_text", voice: [0...1], text: [
                TextEvent(arrival: 0.8, audioEnd: 0.8, text: "a"),
                TextEvent(arrival: 3.6, audioEnd: 0.9, text: "ab"),
                TextEvent(arrival: 4.6, audioEnd: 1, text: "abc"),
                TextEvent(arrival: 5.6, audioEnd: 1, text: "abcd")
            ], desiredStop: 4),
            Scenario(name: "repeated_untimed_text", voice: [0...1], text: [
                TextEvent(arrival: 0.8, audioEnd: 0.8, text: "a"),
                TextEvent(arrival: 3.6, audioEnd: nil, text: "ab"),
                TextEvent(arrival: 4.2, audioEnd: nil, text: "abc"),
                TextEvent(arrival: 4.5, audioEnd: nil, text: "abcd"),
                TextEvent(arrival: 5.4, audioEnd: nil, text: "abcde")
            ], desiredStop: 4)
        ]
    }

    static func status(_ stop: Double?, desired: Double) -> String {
        guard let stop else { return "NO_STOP" }
        if stop < desired - 0.2 { return "EARLY" }
        if stop > desired + 0.7 { return "LATE" }
        return "WITHIN_WINDOW"
    }

    static func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? ">12" }
}

enum LightweightEndpointValidationTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Offline endpoint comparison reports synthetic benefits and known failures") {
            let results = EndpointExperiment.scenarios.map(EndpointExperiment.evaluate)
            print("ENDPOINT_EXPERIMENT synthetic PCM only; 16 kHz; 40 ms frames; shared D=3 s for algorithm comparison (historical default was 2 s); no production integration")
            for r in results {
                let expected = r.scenario.desiredStop
                print("ENDPOINT_ROW \(r.scenario.name) desired=\(EndpointExperiment.number(expected)) text=\(EndpointExperiment.number(r.text))/\(EndpointExperiment.status(r.text, desired: expected)) legacy=\(EndpointExperiment.number(r.legacy))/\(EndpointExperiment.status(r.legacy, desired: expected)) candidate=\(EndpointExperiment.number(r.candidate))/\(EndpointExperiment.status(r.candidate, desired: expected)) practical=\(EndpointExperiment.number(r.practical))/\(EndpointExperiment.status(r.practical, desired: expected)) noiseMaxDB=\(String(format: "%.1f", r.noiseFloor)) boundary=\(r.scenario.knownBoundary)")
            }
            for (name, keyPath) in [("text", \EndpointExperiment.Result.text), ("legacy", \EndpointExperiment.Result.legacy), ("candidate", \EndpointExperiment.Result.candidate), ("practical", \EndpointExperiment.Result.practical)] {
                let counts = Dictionary(grouping: results) { EndpointExperiment.status($0[keyPath: keyPath], desired: $0.scenario.desiredStop) }.mapValues(\.count)
                print("ENDPOINT_COUNTS \(name) \(counts.sorted { $0.key < $1.key })")
            }
            func result(_ name: String) throws -> EndpointExperiment.Result {
                try require(results.first { $0.scenario.name == name })
            }
            let sustained = try result("steady_vowel")
            try expect((sustained.candidate ?? 0) >= 10.9)
            try expect((sustained.text ?? 20) < 8 && (sustained.legacy ?? 20) < 8)
            try expect(sustained.noiseFloor <= -69, "Sustained periodic voice must not raise the learned floor")
            let fillers = try result("filler_without_text")
            let soft = try result("soft_voiced")
            let fan = try result("broadband_fan")
            let keyboard = try result("keyboard_clicks")
            let delayed = try result("delayed_timestamped_text")
            let untimed = try result("repeated_untimed_text")
            let tonal = try result("tonal_machine_same_as_voice")
            let thinking = try result("silent_thinking")
            let veryQuiet = try result("very_quiet_voiced")
            let unvoiced = try result("unvoiced_without_text")
            let untimedLive = try result("unvoiced_live_untimed_text")
            try expect((fillers.candidate ?? 0) >= 11.2)
            try expect((soft.candidate ?? 0) >= 10.9)
            try expect((fan.candidate ?? 20) <= 3.1)
            try expect((keyboard.candidate ?? 20) <= 3.1)
            try expect((delayed.candidate ?? 20) <= 4.2)
            try expect((untimed.candidate ?? 20) <= 4.8)
            // 明确保留反例，测试通过并不代表这些场景被算法解决。
            try expect(tonal.candidate == nil)
            try expect((thinking.candidate ?? 20) < 7)
            try expect((veryQuiet.candidate ?? 20) < 8)
            try expect((unvoiced.candidate ?? 20) < 8)
            try expect((untimedLive.candidate ?? 20) < 8,
                       "Known integration gap: bounded untimed grace loses genuine ongoing text")
            try expect((untimedLive.text ?? 0) >= 10.9,
                       "Text-only baseline must preserve the same genuine ongoing text")
            try expect((untimedLive.practical ?? 0) >= 10.9,
                       "Practical candidate must preserve genuine text with the current callback shape")
            try expect((untimed.practical ?? 0) >= 8.3,
                       "Known tradeoff: untimed backlog growth also extends the practical candidate")
        }
        await runner.run("Offline endpoint proposal rejects late activity and old generations") {
            var policy = EndpointExperiment.Candidate()
            let token = try require(policy.proposal(at: 3.2))
            policy.noteActivity(at: 3.1)
            policy.commit(token, at: 3.2)
            try expect(policy.stop == nil)
            let next = try require(policy.proposal(at: 6.2))
            policy = EndpointExperiment.Candidate(generation: 2)
            policy.commit(next, at: 6.2)
            policy.observe(.init(arrival: 2.9, audioEnd: 2.9, text: "old", generation: 1))
            try expect(policy.lastActivity == 0 && policy.stop == nil)
            var practical = EndpointExperiment.Candidate(allowUntimedGrowthHeartbeat: true)
            practical.observe(.init(arrival: 1, audioEnd: nil, text: "hello"))
            practical.observe(.init(arrival: 2, audioEnd: nil, text: "hello... "))
            practical.observe(.init(arrival: 3, audioEnd: nil, text: "hello... "))
            try expect(practical.lastActivity == 1 && practical.deadlineExtension == 0,
                       "Punctuation, whitespace and duplicate text must not extend the practical candidate")
        }
        await runner.run("Offline endpoint feature microbenchmark reports cost separately from synthesis") {
            let audio = EndpointExperiment.pcm(.init(name: "benchmark", voice: [0...1], desiredStop: 4), duration: 1)
            let repeats = 40
            var checksum = 0.0
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<repeats {
                var policy = EndpointExperiment.Candidate()
                for (index, frame) in audio.enumerated() {
                    let features = EndpointExperiment.features(frame)
                    policy.observe(features, time: Double(index + 1) * EndpointExperiment.frameDuration)
                    checksum += features.periodicity + policy.lastActivity
                }
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            #if DEBUG
            let configuration = "debug"
            #else
            let configuration = "release"
            #endif
            print("ENDPOINT_MICROBENCH configuration=\(configuration) audioSeconds=\(repeats) wallMS=\(String(format: "%.2f", milliseconds)) wallMSPerAudioSecond=\(String(format: "%.3f", milliseconds / Double(repeats))) frameSamples=640 correlationLags=41 reducedSamples=160 checksum=\(String(format: "%.2f", checksum))")
            try expect(checksum.isFinite && checksum > 0)
        }
    }
}
