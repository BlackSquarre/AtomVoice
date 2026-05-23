import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum RecognitionSessionTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("RecognitionSession capabilities expose route-change reload needs") {
            let provider = ASREngineProvider()
            let audioEngine = AudioEngineController()

            let apple = provider.recognitionSession(for: ASREngineRegistry.appleCode, audioEngine: audioEngine)
            let sherpa = provider.recognitionSession(for: ASREngineRegistry.sherpaCode, audioEngine: audioEngine)
            let doubao = provider.recognitionSession(for: VolcengineASRSettings.engineCode, audioEngine: audioEngine)

            try expect(!apple.requiresModelReloadOnRouteChange)
            try expect(sherpa.requiresModelReloadOnRouteChange)
            try expect(!doubao.requiresModelReloadOnRouteChange)
        }
        await runner.run("RecognitionSession callbacks separate generation from active recording") {
            var generation = 1
            var isRecording = true
            let callbacks = makeRecognitionSessionCallbacks(
                generationProvider: { generation },
                isRecordingProvider: { isRecording }
            )

            try expect(callbacks.isCurrent())
            try expect(callbacks.isRecordingCurrent())

            isRecording = false
            try expect(callbacks.isCurrent())
            try expect(!callbacks.isRecordingCurrent())

            generation = 2
            try expect(!callbacks.isCurrent())
            try expect(!callbacks.isRecordingCurrent())
        }
    }
}
