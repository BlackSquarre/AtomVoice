import Foundation

// 最终识别结果收尾所需的胶囊 UI 行为，方便用 fake 独立测试。
protocol RecognitionResultPresenting: AnyObject {
    func updateRecognitionText(_ text: String)
    func showRecognitionRefining()
    func showRecognitionError(_ message: String, dismissAfter: TimeInterval)
    func dismissRecognition(completion: (() -> Void)?)
}

extension CapsuleWindowController: RecognitionResultPresenting {
    func updateRecognitionText(_ text: String) {
        updateText(text)
    }

    func showRecognitionRefining() {
        showRefining()
    }

    func showRecognitionError(_ message: String, dismissAfter: TimeInterval) {
        showError(message, dismissAfter: dismissAfter)
    }

    func dismissRecognition(completion: (() -> Void)?) {
        dismiss(completion: completion)
    }
}

// LLM 润色协议：生产代码用 LLMRefiner，测试用 fake。
protocol RecognitionTextRefining: AnyObject {
    func refine(
        text: String,
        onProgress: ((String) -> Void)?,
        completion: @escaping (String?, String?) -> Void
    )
}

extension LLMRefiner: RecognitionTextRefining {}

struct RecognitionLiveInsertionSnapshot {
    let isActive: Bool
    let committedText: String

    var hasCommittedText: Bool {
        !committedText.isEmpty
    }
}

enum RecognitionFinalizationMode {
    case normal
    case immediate(appending: String?)
}

/// 把 ASR raw text 收敛为最终上屏动作：自动标点、LLM、流式替换、立即标点和空文本兜底。
final class RecognitionResultFinalizer {
    struct Settings {
        var language: String
        var llmEnabled: Bool
        var llmAPIKey: String
        var llmResultDelay: Double
    }

    struct Request {
        let recognizedText: String
        let errorMessage: String?
        let mode: RecognitionFinalizationMode
        let engineCode: String
        let liveInsertion: RecognitionLiveInsertionSnapshot
        let streamSession: TextStreamSession?
        let clearStreamSession: () -> Void
    }

    private let presenter: RecognitionResultPresenting
    private let refiner: RecognitionTextRefining
    private let textPostProcessorRegistry: TextPostProcessorRegistry
    private let outputSinkProvider: () -> TextOutputSink
    private let settingsProvider: () -> Settings

    init(
        presenter: RecognitionResultPresenting,
        refiner: RecognitionTextRefining,
        textPostProcessorRegistry: TextPostProcessorRegistry,
        outputSinkProvider: @escaping () -> TextOutputSink,
        settingsProvider: @escaping () -> Settings
    ) {
        self.presenter = presenter
        self.refiner = refiner
        self.textPostProcessorRegistry = textPostProcessorRegistry
        self.outputSinkProvider = outputSinkProvider
        self.settingsProvider = settingsProvider
    }

    func finish(_ request: Request) {
        let rawText = remainingTextAfterLiveInsertion(
            request.recognizedText,
            liveInsertion: request.liveInsertion
        )

        switch request.mode {
        case .normal:
            finishRecording(rawText: rawText, errorMessage: request.errorMessage, request: request)
        case .immediate(let punctuation):
            finishImmediateRecording(
                rawText: rawText,
                punctuation: punctuation,
                errorMessage: request.errorMessage,
                request: request
            )
        }
    }

    // MARK: - 普通收尾

    private func finishRecording(rawText: String, errorMessage: String?, request: Request) {
        if let session = request.streamSession {
            finishStreamingRecording(
                session: session,
                rawText: rawText,
                errorMessage: errorMessage,
                request: request
            )
            return
        }

        if rawText.isEmpty {
            showRecordingResultErrorOrDismiss(errorMessage)
            return
        }

        let processedText = processedTextForFinalResult(rawText, request: request)
        if shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: true, liveInsertion: request.liveInsertion) {
            presenter.showRecognitionRefining()
            refiner.refine(text: processedText, onProgress: { [weak self] partial in
                self?.presenter.updateRecognitionText(partial)
            }) { [weak self] refined, errorMessage in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let errorMessage {
                        // LLM 失败时保持原行为：先把未润色文本上屏，同时展示错误。
                        self.outputSinkProvider().deliver(text: processedText, completion: nil)
                        self.presenter.showRecognitionError(errorMessage, dismissAfter: 3)
                        return
                    }
                    let finalText = refined ?? processedText
                    self.presenter.updateRecognitionText(finalText)
                    let delay = self.settingsProvider().llmResultDelay
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.presenter.dismissRecognition {
                            self.outputSinkProvider().deliver(text: finalText, completion: nil)
                        }
                    }
                }
            }
        } else {
            dismissAndDeliver(processedText)
        }
    }

    /// 流式 sink 模式下的录音结束流程：替换/补标点/调 LLM，然后关闭 session。
    private func finishStreamingRecording(
        session: TextStreamSession,
        rawText: String,
        errorMessage: String?,
        request: Request
    ) {
        if rawText.isEmpty {
            cancelStreamingResult(session, errorMessage: errorMessage, request: request)
            return
        }

        let processedText = processedTextForFinalResult(rawText, request: request)
        if shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: false, liveInsertion: request.liveInsertion) {
            presenter.showRecognitionRefining()
            refiner.refine(text: processedText, onProgress: { [weak self] partial in
                self?.presenter.updateRecognitionText(partial)
            }) { [weak self] refined, llmError in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let finalText = refined ?? processedText
                    let replacement = llmError != nil ? processedText : finalText
                    self.finalizeStreamSession(session, replacingWith: replacement, request: request)
                    if let llmError {
                        self.presenter.showRecognitionError(llmError, dismissAfter: 3)
                    } else {
                        self.presenter.updateRecognitionText(finalText)
                        let delay = self.settingsProvider().llmResultDelay
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.presenter.dismissRecognition(completion: nil)
                        }
                    }
                }
            }
        } else {
            // 无 LLM：仅在自动标点改了文本时做替换；否则原样提交即可。
            let replacement: String? = (processedText != rawText) ? processedText : nil
            presenter.dismissRecognition { [weak self] in
                self?.finalizeStreamSession(session, replacingWith: replacement, request: request)
            }
        }
    }

    // MARK: - 立即收尾

    private func finishImmediateRecording(
        rawText: String,
        punctuation: String?,
        errorMessage: String?,
        request: Request
    ) {
        if let session = request.streamSession {
            if rawText.isEmpty {
                cancelStreamingImmediateResult(
                    session,
                    errorMessage: errorMessage,
                    punctuation: punctuation,
                    request: request
                )
                return
            }
            let processedText = processedTextForFinalResult(rawText, isImmediateFinish: true, request: request)
            let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)
            presenter.dismissRecognition { [weak self] in
                self?.finalizeStreamSession(
                    session,
                    replacingWith: finalText != rawText ? finalText : nil,
                    request: request
                )
            }
            return
        }

        if rawText.isEmpty {
            if let errorMessage, punctuation?.isEmpty ?? true {
                presenter.showRecognitionError(errorMessage, dismissAfter: 5)
                return
            }

            dismissAndDeliverPunctuationOnly(punctuation)
            return
        }

        let processedText = processedTextForFinalResult(rawText, isImmediateFinish: true, request: request)
        let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)

        dismissAndDeliver(finalText)
    }

    // MARK: - 文本处理

    private func processedTextForFinalResult(
        _ rawText: String,
        isImmediateFinish: Bool = false,
        request: Request
    ) -> String {
        let settings = settingsProvider()
        let context = TextProcessingContext(
            engineCode: request.engineCode,
            language: settings.language,
            isImmediateFinish: isImmediateFinish
        )
        let processedText = textPostProcessorRegistry.run(rawText, context: context)
        if processedText != rawText {
            presenter.updateRecognitionText(processedText)
        }
        return processedText
    }

    private func textByAppendingImmediatePunctuation(_ punctuation: String?, to text: String) -> String {
        guard let punctuation, !punctuation.isEmpty else { return text }
        return removingTrailingSentencePunctuation(from: text) + punctuation
    }

    private func removingTrailingSentencePunctuation(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            result.removeLast()
        }
        return result
    }

    private func shouldRunLLMRefinement(
        skipWhenLiveInsertionCommitted: Bool,
        liveInsertion: RecognitionLiveInsertionSnapshot
    ) -> Bool {
        let settings = settingsProvider()
        guard settings.llmEnabled, !settings.llmAPIKey.isEmpty else { return false }
        return !(skipWhenLiveInsertionCommitted && liveInsertion.hasCommittedText)
    }

    private func remainingTextAfterLiveInsertion(
        _ text: String,
        liveInsertion: RecognitionLiveInsertionSnapshot
    ) -> String {
        guard liveInsertion.isActive, !liveInsertion.committedText.isEmpty else { return text }

        if text.hasPrefix(liveInsertion.committedText) {
            return String(text.dropFirst(liveInsertion.committedText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let committed = liveInsertion.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty, text.hasPrefix(committed) {
            return String(text.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commonPrefixEnd = commonPrefixEndIndex(in: text, with: liveInsertion.committedText)
        let commonPrefixLength = text.distance(from: text.startIndex, to: commonPrefixEnd)
        if commonPrefixLength > 0 {
            DebugLog.info("[LiveInsertion] 最终文本与已上屏前缀不完全一致，从共同前缀后继续注入")
            return String(text[commonPrefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        DebugLog.info("[LiveInsertion] 最终文本与已上屏前缀不一致，注入完整最终文本以避免丢字")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commonPrefixEndIndex(in text: String, with prefix: String) -> String.Index {
        var textIndex = text.startIndex
        var prefixIndex = prefix.startIndex

        while textIndex < text.endIndex,
              prefixIndex < prefix.endIndex,
              text[textIndex] == prefix[prefixIndex] {
            textIndex = text.index(after: textIndex)
            prefixIndex = prefix.index(after: prefixIndex)
        }

        return textIndex
    }

    // MARK: - 收尾动作

    private func showRecordingResultErrorOrDismiss(_ errorMessage: String?) {
        if let errorMessage {
            presenter.showRecognitionError(errorMessage, dismissAfter: 5)
        } else {
            presenter.dismissRecognition(completion: nil)
        }
    }

    private func cancelStreamingResult(
        _ session: TextStreamSession,
        errorMessage: String?,
        request: Request
    ) {
        session.cancel()
        request.clearStreamSession()
        showRecordingResultErrorOrDismiss(errorMessage)
    }

    private func cancelStreamingImmediateResult(
        _ session: TextStreamSession,
        errorMessage: String?,
        punctuation: String?,
        request: Request
    ) {
        session.cancel()
        request.clearStreamSession()
        if let errorMessage, punctuation?.isEmpty ?? true {
            presenter.showRecognitionError(errorMessage, dismissAfter: 5)
            return
        }
        dismissAndDeliverPunctuationOnly(punctuation)
    }

    private func finalizeStreamSession(
        _ session: TextStreamSession,
        replacingWith replacement: String?,
        request: Request
    ) {
        session.finalize(replacingWith: replacement) {
            request.clearStreamSession()
        }
    }

    private func dismissAndDeliver(_ text: String) {
        presenter.dismissRecognition { [self] in
            outputSinkProvider().deliver(text: text, completion: nil)
        }
    }

    private func dismissAndDeliverPunctuationOnly(_ punctuation: String?) {
        presenter.dismissRecognition { [self] in
            if let punctuation, !punctuation.isEmpty {
                outputSinkProvider().deliver(text: punctuation, completion: nil)
            }
        }
    }
}
