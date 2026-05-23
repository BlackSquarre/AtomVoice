import Foundation

extension RecordingSessionController {
    @discardableResult
    func dispatch(_ event: RecordingEvent) -> [RecordingSideEffect] {
        let result = RecordingStateMachine.reduce(state, event)
        state = result.state
        execute(result.sideEffects)
        return result.sideEffects
    }

    func execute(_ sideEffects: [RecordingSideEffect]) {
        sideEffects.forEach(execute)
    }

    func execute(_ sideEffect: RecordingSideEffect) {
        switch sideEffect {
        case .waitForInputReady(let request):
            waitForInputReady(startRequest: request)
        case .validateStart(let request):
            continueStartRecording(startRequest: request)
        case .startSession(let generation):
            startRecognitionSession(generation: generation)
        case .stopSession(let generation, let immediate, let punctuation):
            stopRecognitionSession(generation: generation, immediate: immediate, appending: punctuation)
        case .cancelSession(let stopAudioEngine):
            recognitionSession?.cancel()
            if stopAudioEngine {
                audioEngine.stop()
            }
        case .showCapsule(let presentation, let ensurePanel):
            presentCapsule(presentation, ensurePanel: ensurePanel)
        case .updateCapsuleText(let text):
            presenter.present(.updateText(text))
            streamSession?.update(currentText: text)
        case .updateCapsuleBands:
            break
        case .startShimmer:
            presenter.present(.startShimmer)
        case .stopShimmer:
            presenter.present(.stopShimmer)
        case .dismissCapsule:
            presenter.dismiss(completion: nil)
        case .deliverText(let text):
            activeOutputSink.deliver(text: text, completion: nil)
        case .startLLM:
            break
        case .cancelLLM:
            llmRefiner.cancel()
        case .lowerVolume:
            volumeController.saveAndDecreaseVolume()
        case .restoreVolume:
            volumeController.restoreVolume()
        case .startSilenceMonitor:
            asrSilenceMonitor.start()
        case .stopSilenceMonitor:
            asrSilenceMonitor.stop()
        case .notifyRecording(let active):
            onRecordingStateChanged?(active)
        case .notifyRefining(let active):
            onRefiningStateChanged?(active)
        case .noteASRText(let text):
            asrSilenceMonitor.noteText(text)
        case .activateTextOutput:
            activateTextOutputForRecordingIfNeeded()
        case .resetStreamSession:
            streamSession?.cancel()
            streamSession = nil
        case .clearSwitchedAudioRequest:
            audioEngine.clearSwitchedRequest()
        case .resetAudioAnalyzer:
            audioAnalyzer.reset()
        case .abandonAudioRouteRecovery:
            audioEngine.abandonAfterRouteRecoveryFailure()
        case .notifySessionDidEnd:
            delegate?.sessionDidEnd()
        case .requestSherpaModelDownload(let redownload, let delay):
            SherpaModelDownloader.printMissingRequiredFiles()
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.delegate?.sessionRequiresSherpaModelDownload(redownload: redownload)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.sessionRequiresSherpaModelDownload(redownload: redownload)
                }
            }
        }
    }

    func presentCapsule(_ presentation: RecordingCapsulePresentationRequest, ensurePanel: Bool) {
        switch presentation {
        case .none:
            break
        case .initial:
            presenter.present(.showInitial(compactStatusKey: streamingCompactKey))
        case .recording:
            presenter.present(.showRecording)
        case .progress(let text, let hidesWaveform):
            presenter.present(.showProgress(text: text, hidesWaveform: hidesWaveform))
        case .error(let message, let dismissAfter):
            presenter.present(.showError(message: message, dismissAfter: dismissAfter, ensurePanel: ensurePanel))
        }
    }
}
