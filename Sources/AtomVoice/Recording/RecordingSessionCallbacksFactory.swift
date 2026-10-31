import AVFoundation
import Foundation

extension RecordingSessionController {
    func makeRecognitionSessionCallbacks(generation: Int) -> RecognitionSessionCallbacks {
        RecognitionSessionCallbacks(
            audioInput: recordingAudioInput,
            isCurrent: { [weak self] in
                self?.recordingGeneration == generation
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
            onShowInitial: { [weak self] in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                self.showInitialCapsule()
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
            onDisplayText: { [weak self] text in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                self.updateCapsuleText(text)
            },
            onShimmerChanged: { [weak self] active in
                guard let self, self.recordingGeneration == generation,
                      self.isRecordingOrStarting else { return }
                active ? self.applyCapsuleShimmer() : self.stopCapsuleShimmer()
            },
            onEffectiveEngineChanged: { [weak self] code in
                guard let self, self.recordingGeneration == generation,
                      self.state.isRecordingOrStarting || self.state.phase == .stopping else { return }
                self.dispatch(.fallbackStarted(engine: code))
            },
            onStartFailure: { [weak self] failure in
                guard let self, self.recordingGeneration == generation,
                      self.state.isRecordingOrStarting else { return }
                #if DEBUG_BUILD
                self.preserveDebugAudioEvidence(reason: .sessionStartFailed)
                #endif
                self.dispatch(
                    .sessionStartFailed(
                        message: failure.message,
                        dismissAfter: failure.dismissAfter,
                        stopAudioEngine: failure.stopAudioEngine,
                        recovery: failure.recovery.map {
                            switch $0 {
                            case .requestSherpaModelDownload(let redownload, let delay):
                                return .requestSherpaModelDownload(redownload: redownload, delay: delay)
                            }
                        }
                    )
                )
            },
            onWaitingForFinalResultChanged: { [weak self] waiting in
                guard let self, self.recordingGeneration == generation else { return }
                self.dispatch(waiting ? .doubaoFinalWaitStarted : .doubaoFinalWaitEnded)
            },
            onResetLiveInsertion: { [weak self] in
                guard let self, self.recordingGeneration == generation else { return }
                self.dispatch(.liveInsertionReset)
            }
        )
    }
}
