import AppKit
import AVFoundation
import Foundation
import MediaPlayer

let logURL = URL(fileURLWithPath: "/tmp/atomvoice-now-playing-probe.log")

final class SilentAudioPlayer {
    private var player: AVAudioPlayer?
    private var fileURL: URL?

    func play() {
        guard player == nil else { return }
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("atomvoice-now-playing-probe-silence.wav")
            try Self.makeSilentWavData().write(to: url, options: [.atomic])
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.0001
            player.prepareToPlay()
            let started = player.play()
            self.player = player
            self.fileURL = url
            log("silent AVAudioPlayer started=\(started), isPlaying=\(player.isPlaying), url=\(url.path)")
        } catch {
            log("silent AVAudioPlayer failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        log("silent AVAudioPlayer stopped")
    }

    var statusText: String {
        "playerExists=\(player != nil) isPlaying=\(player?.isPlaying ?? false)"
    }

    private static func makeSilentWavData() -> Data {
        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let durationSeconds = 1.0
        let sampleCount = UInt32(Double(sampleRate) * durationSeconds)
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleCount * UInt32(channels) * bytesPerSample

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        appendLE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(channels, to: &data)
        appendLE(sampleRate, to: &data)
        appendLE(sampleRate * UInt32(channels) * bytesPerSample, to: &data)
        appendLE(UInt16(UInt32(channels) * bytesPerSample), to: &data)
        appendLE(bitsPerSample, to: &data)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        appendLE(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

final class NowPlayingHijackProbe {
    private let player = SilentAudioPlayer()
    private var targets: [Any] = []
    private var heartbeatTimer: Timer?

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        player.play()
        configureNowPlaying()
        configureCommands()
        startHeartbeat()
        log("probe running. Start Apple Music/Spotify playback, then press headset Play/Pause.")
        log("Press Ctrl-C in the terminal to stop this probe.")
    }

    private func configureNowPlaying() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "AtomVoice Now Playing Probe",
            MPMediaItemPropertyArtist: "AtomVoice Debug",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPMediaItemPropertyPlaybackDuration: 3_600,
            MPNowPlayingInfoPropertyPlaybackRate: 1
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
        log("nowPlayingInfo set, playbackState=.playing")
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true

        targets.append(center.togglePlayPauseCommand.addTarget { event in
            log("MPRemoteCommandCenter togglePlayPause received: \(type(of: event))")
            return .success
        })
        targets.append(center.playCommand.addTarget { event in
            log("MPRemoteCommandCenter play received: \(type(of: event))")
            return .success
        })
        targets.append(center.pauseCommand.addTarget { event in
            log("MPRemoteCommandCenter pause received: \(type(of: event))")
            return .success
        })
        log("remote command handlers registered")
    }

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MPNowPlayingInfoCenter.default().playbackState = .playing
            log("heartbeat: playbackState=.playing \(self.player.statusText)")
        }
    }
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(formatter.string(from: Date()))] \(message)"
    print(line)
    fflush(stdout)
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

let probe = NowPlayingHijackProbe()
try? FileManager.default.removeItem(at: logURL)
probe.start()
RunLoop.main.run()
