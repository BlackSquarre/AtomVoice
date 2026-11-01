import AVFoundation
import Foundation

extension RecordingSessionController {
    func makeRecognitionSessionCallbacks(generation: Int, finalization: RecordingFinalization? = nil, audioInput: RecordingAudioInput? = nil) -> RecognitionSessionCallbacks {
        RecognitionSessionCallbacks(
            audioInput: audioInput ?? recordingAudioInput,
            isCurrent: { [weak self] in
                finalization.map { $0.isOutputValid && $0.isRecognitionPending } ?? (self?.recordingGeneration == generation)
            },
            isRecordingCurrent: { [weak self] in
                guard let self else { return false }
                return self.isRecording && !self.pendingStopForPresentation && self.recordingGeneration == generation
            },
            copyAudioBuffer: { [weak self] buffer in
                self?.copyAudioBuffer(buffer)
            },
            onPartialResult: { [weak self] text, isFinal in
                guard let self, self.recordingGeneration == generation,
                      self.isRecording || self.state.phase == .stopping else { return }
                ASRLatencyProbe.mark(text, stage: "callbacks_partial", isFinal: isFinal)
                self.dispatch(.asrPartial(text: text, isFinal: isFinal))
                self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
            },
            onError: { [weak self] message in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                self.showCapsuleError(message, dismissAfter: 5)
            },
            onShowRecording: { [weak self] in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                self.showRecordingCapsule()
            },
            onProgress: { [weak self] text, hidesWaveform in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                self.showCapsuleProgress(text, hidesWaveform: hidesWaveform)
            },
            onShimmerChanged: { [weak self] active in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                active ? self.applyCapsuleShimmer() : self.stopCapsuleShimmer()
            },
            onEffectiveEngineChanged: { [weak self] code in
                finalization?.engineCode = code
                guard let self, self.recordingGeneration == generation,
                      self.state.isRecordingOrStarting || self.state.phase == .stopping else { return }
                self.dispatch(.fallbackStarted(engine: code))
            },
            onWaitingForFinalResultChanged: { [weak self] waiting in
                guard let self, self.recordingGeneration == generation else { return }
                self.dispatch(waiting ? .doubaoFinalWaitStarted : .doubaoFinalWaitEnded)
            },
            onResetLiveInsertion: { [weak self] in
                guard let self, self.recordingGeneration == generation else { return }
                self.dispatch(.liveInsertionReset)
            },
            onPreparationStage: { [weak self] stage in
                guard let self, self.recordingGeneration == generation, self.isRecordingOrStarting else { return }
                self.recognitionPreparationStageChanged(stage)
            }
        )
    }
}
