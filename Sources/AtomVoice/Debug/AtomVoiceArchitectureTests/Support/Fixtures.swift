import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

@discardableResult
func step(_ state: inout RecordingSessionState, _ event: RecordingEvent) -> [RecordingSideEffect] {
    let result = RecordingStateMachine.reduce(state, event)
    state = result.state
    return result.sideEffects
}


func makeTemporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AtomVoiceArchitectureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func writeDummyFile(_ url: URL) throws {
    try Data([0x41]).write(to: url)
}

func makePCMBuffer(
    sampleRate: Double,
    frameLength: AVAudioFrameCount,
    fillValue: Float? = nil,
    sine: (frequency: Double, amplitude: Float, phase: Double)? = nil
) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
    buffer.frameLength = frameLength
    if let channel = buffer.floatChannelData?[0] {
        if let sine {
            let twoPi = 2.0 * Double.pi
            for index in 0..<Int(frameLength) {
                let t = Double(index) / sampleRate
                channel[index] = sine.amplitude * Float(sin(twoPi * sine.frequency * t + sine.phase))
            }
        } else {
            for index in 0..<Int(frameLength) {
                channel[index] = fillValue ?? Float(index) / 100.0
            }
        }
    }
    return buffer
}

func makeRecognitionSessionCallbacks(
    generationProvider: @escaping () -> Int = { 1 },
    isRecordingProvider: @escaping () -> Bool = { true },
    targetGeneration: Int = 1
) -> RecognitionSessionCallbacks {
    RecognitionSessionCallbacks(
        isCurrent: {
            generationProvider() == targetGeneration
        },
        isRecordingCurrent: {
            isRecordingProvider() && generationProvider() == targetGeneration
        },
        copyAudioBuffer: { buffer in buffer },
        onPartialResult: { _, _ in },
        onError: { _ in },
        onShowInitial: {},
        onShowRecording: {},
        onProgress: { _, _ in },
        onDisplayText: { _ in },
        onShimmerChanged: { _ in },
        onEffectiveEngineChanged: { _ in },
        onStartFailure: { _ in },
        onWaitingForFinalResultChanged: { _ in },
        onResetLiveInsertion: {}
    )
}

final class RecordingSessionHarness {
    let audioEngine = AudioEngineController()
    let presenter = FakeRecordingSessionPresenter()
    let session: FakeRecognitionSession
    let provider = FakeASREngineProvider()
    let outputSink: FakeTextOutputSink
    let delegate = FakeRecordingSessionDelegate()
    let controller: RecordingSessionController

    init(
        session: FakeRecognitionSession = FakeRecognitionSession(),
        outputSink: FakeTextOutputSink = FakeTextOutputSink(),
        processors: [TextPostProcessor] = []
    ) {
        self.session = session
        self.outputSink = outputSink
        provider.register(session)
        controller = RecordingSessionController(
            audioEngine: audioEngine,
            presenter: presenter,
            llmRefiner: LLMRefiner(),
            textPostProcessorRegistry: TextPostProcessorRegistry(processors: processors),
            textOutputSinkRegistry: TextOutputSinkRegistry(sinks: [outputSink], fallbackCode: outputSink.descriptor.code),
            volumeController: VolumeController(),
            asrEngineRegistry: ASREngineRegistry.shared,
            asrEngineProvider: provider
        )
        controller.delegate = delegate
    }

    @discardableResult
    func enterStarting(deferCapsulePresentation: Bool = false) -> Int {
        var state = RecordingSessionState()
        _ = step(&state, .triggerPressed(deferCapsulePresentation: deferCapsulePresentation))
        controller.state = state
        return state.startRequestGeneration
    }

    @discardableResult
    func enterCapturing(engine: String = ASREngineRegistry.appleCode) -> Int {
        var state = RecordingSessionState()
        _ = step(&state, .triggerPressed(deferCapsulePresentation: false))
        _ = step(&state, .inputPreflightCompleted(request: state.startRequestGeneration, ready: true))
        _ = step(
            &state,
            .recognitionCapabilitiesResolved(
                mutableCapsulePreview: session.supportsMutableCapsulePreview
            )
        )
        _ = step(
            &state,
            .startValidated(
                engine: engine,
                pendingDoubaoText: nil,
                pendingRefinementText: nil,
                lowerVolume: false
            )
        )
        controller.state = state
        controller.recognitionSession = session
        return state.recordingGeneration
    }

    func tearDown() {
        controller.asrSilenceMonitor.stop()
        controller.recognitionSession?.cancel()
        controller.streamSession?.cancel()
        controller.streamSession = nil
    }
}

final class RecognitionFinalizerHarness {
    let presenter = FakeRecognitionPresenter()
    let refiner = FakeRecognitionRefiner()
    let sink = FakeTextOutputSink()
    let settings: RecognitionFinalizerSettingsBox
    private(set) var clearedStreamCount = 0
    var generation = 0
    var isRefining = false
    private let finalizer: RecognitionResultFinalizer

    init(processors: [TextPostProcessor] = []) {
        let settings = RecognitionFinalizerSettingsBox()
        self.settings = settings
        let finalizer = RecognitionResultFinalizer(
            presenter: presenter,
            refiner: refiner,
            textPostProcessorRegistry: TextPostProcessorRegistry(processors: processors),
            outputSinkProvider: { [sink] in sink },
            settingsProvider: { settings.value }
        )
        self.finalizer = finalizer
        
        finalizer.onRefiningStateChanged = { [weak self] refining, _ in
            self?.isRefining = refining
        }
        finalizer.currentGenerationProvider = { [weak self] in
            self?.generation ?? 0
        }
    }

    func finish(
        _ text: String,
        mode: RecognitionFinalizationMode = .normal,
        errorMessage: String? = nil,
        liveInsertion: RecognitionLiveInsertionSnapshot = RecognitionLiveInsertionSnapshot(isActive: false, committedText: ""),
        streamSession: TextStreamSession? = nil
    ) {
        finalizer.finish(
            RecognitionResultFinalizer.Request(
                recognizedText: text,
                errorMessage: errorMessage,
                mode: mode,
                engineCode: ASREngineRegistry.appleCode,
                liveInsertion: liveInsertion,
                streamSession: streamSession,
                clearStreamSession: { [weak self] in self?.clearedStreamCount += 1 },
                generation: generation
            )
        )
    }

    func remainingText(_ text: String, committedText: String) -> String {
        finalizer.remainingTextAfterLiveInsertion(
            text,
            liveInsertion: RecognitionLiveInsertionSnapshot(isActive: true, committedText: committedText)
        )
    }
}

final class RecognitionFinalizerSettingsBox {
    var value = RecognitionResultFinalizer.Settings(
        language: "en-US",
        llmEnabled: false,
        llmAPIKey: "",
        llmResultDelay: 0
    )

    var language: String {
        get { value.language }
        set { value.language = newValue }
    }

    var llmEnabled: Bool {
        get { value.llmEnabled }
        set { value.llmEnabled = newValue }
    }

    var llmAPIKey: String {
        get { value.llmAPIKey }
        set { value.llmAPIKey = newValue }
    }

    var llmResultDelay: Double {
        get { value.llmResultDelay }
        set { value.llmResultDelay = newValue }
    }
}
