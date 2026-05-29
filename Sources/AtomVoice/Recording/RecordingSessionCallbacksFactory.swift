import AVFoundation
import Foundation

extension RecordingSessionController {
    func makeRecognitionSessionCallbacks(generation: Int) -> RecognitionSessionCallbacks {
        RecognitionSessionCallbacks(
            isCurrent: { [weak self] in
                self?.recordingGeneration == generation
            },
            isRecordingCurrent: { [weak self] in
                guard let self else { return false }
                return self.isRecording && self.recordingGeneration == generation
            },
            copyAudioBuffer: { [weak self] buffer in
                self?.copyAudioBuffer(buffer)
            },
            onPartialResult: { [weak self] text, isFinal in
                guard let self else { return }
                ASRLatencyProbe.mark(text, stage: "callbacks_partial", isFinal: isFinal)
                self.dispatch(.asrPartial(text: text, isFinal: isFinal))
                self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
            },
            onError: { [weak self] message in
                self?.showCapsuleError(message, dismissAfter: 5)
            },
            onShowInitial: { [weak self] in
                self?.showInitialCapsule()
            },
            onShowRecording: { [weak self] in
                self?.showRecordingCapsule()
            },
            onProgress: { [weak self] text, hidesWaveform in
                self?.showCapsuleProgress(text, hidesWaveform: hidesWaveform)
            },
            onDisplayText: { [weak self] text in
                self?.updateCapsuleText(text)
            },
            onShimmerChanged: { [weak self] active in
                active ? self?.applyCapsuleShimmer() : self?.stopCapsuleShimmer()
            },
            onEffectiveEngineChanged: { [weak self] code in
                self?.dispatch(.fallbackStarted(engine: code))
            },
            onStartFailure: { [weak self] failure in
                self?.dispatch(
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
                self?.dispatch(waiting ? .doubaoFinalWaitStarted : .doubaoFinalWaitEnded)
            },
            onResetLiveInsertion: { [weak self] in
                self?.dispatch(.liveInsertionReset)
            }
        )
    }
}
