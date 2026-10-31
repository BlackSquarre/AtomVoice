import Foundation

// 最终识别结果收尾所需的胶囊 UI 行为，方便用 fake 独立测试。
protocol RecognitionResultPresenting: AnyObject {
    func updateRecognitionText(_ text: String)
    func showRecognitionRefining()
    func showRecognitionError(_ message: String, dismissAfter: TimeInterval)
    func dismissRecognition(completion: (() -> Void)?)
    func dismissRecognitionImmediately()
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
        let generation: Int
        var preparedText: String? = nil
        var waitForPriorOutput: (@escaping () -> Void) -> Void = { $0() }
    }

    private let presenter: RecognitionResultPresenting
    private let refiner: RecognitionTextRefining
    private let textPostProcessorRegistry: TextPostProcessorRegistry
    private let outputSinkProvider: () -> TextOutputSink
    private let settingsProvider: () -> Settings

    var onRefiningStateChanged: ((Bool, String?) -> Void)?
    var currentGenerationProvider: (() -> Int)?

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
        guard isGenerationValid(request.generation) else { return }
        let rawText = remainingTextAfterLiveInsertion(
            request.recognizedText,
            liveInsertion: request.liveInsertion
        )

        if request.engineCode == ASREngineRegistry.sherpaCode, !rawText.isEmpty {
            let immediate: Bool
            if case .immediate = request.mode { immediate = true } else { immediate = false }
            let context = TextProcessingContext(engineCode: request.engineCode,
                language: settingsProvider().language, isImmediateFinish: immediate)
            textPostProcessorRegistry.runAsync(rawText, context: context) { [weak self] text in
                guard let self, self.isGenerationValid(request.generation) else { return }
                var prepared = request
                prepared.preparedText = text
                self.finishPrepared(prepared, rawText: rawText)
            }
            return
        }
        finishPrepared(request, rawText: rawText)
    }

    private func finishPrepared(_ request: Request, rawText: String) {
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

    private func isGenerationValid(_ generation: Int) -> Bool {
        guard let provider = currentGenerationProvider else { return true }
        return provider() == generation
    }

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
            showRecordingResultErrorOrDismiss(errorMessage, request: request)
            return
        }

        let processedText = processedTextForFinalResult(rawText, request: request)
        if shouldRunLLMRefinement(skipWhenLiveInsertionCommitted: true, liveInsertion: request.liveInsertion) {
            onRefiningStateChanged?(true, processedText)
            presenter.showRecognitionRefining()
            refiner.refine(text: processedText, onProgress: { [weak self] partial in
                guard let self, self.isGenerationValid(request.generation) else { return }
                self.presenter.updateRecognitionText(partial)
            }) { [weak self] refined, errorMessage in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.isGenerationValid(request.generation) else { return }
                    self.onRefiningStateChanged?(false, nil)
                    if let errorMessage {
                        // LLM 失败时保持原行为：先把未润色文本上屏，同时展示错误。
                        self.deliverAndFinish(processedText, request: request, errorMessage: errorMessage)
                        return
                    }
                    let finalText = refined ?? processedText
                    self.presenter.updateRecognitionText(finalText)
                    self.deliverAndFinish(finalText, request: request)
                }
            }
        } else {
            deliverAndFinish(processedText, request: request)
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
            onRefiningStateChanged?(true, processedText)
            presenter.showRecognitionRefining()
            refiner.refine(text: processedText, onProgress: { [weak self] partial in
                guard let self, self.isGenerationValid(request.generation) else { return }
                self.presenter.updateRecognitionText(partial)
            }) { [weak self] refined, llmError in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.isGenerationValid(request.generation) else { return }
                    self.onRefiningStateChanged?(false, nil)
                    let finalText = refined ?? processedText
                    let replacement = llmError != nil ? processedText : finalText
                    if let llmError {
                        self.finalizeStreamSession(session, replacingWith: replacement, request: request,
                                                   errorMessage: llmError)
                    } else {
                        self.presenter.updateRecognitionText(finalText)
                        self.finalizeStreamSession(session, replacingWith: replacement, request: request)
                    }
                }
            }
        } else {
            // 无 LLM：仅在自动标点改了文本时做替换；否则原样提交即可。
            let replacement: String? = (processedText != rawText) ? processedText : nil
            finalizeStreamSession(session, replacingWith: replacement, request: request)
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
            finalizeStreamSession(session, replacingWith: finalText != rawText ? finalText : nil, request: request)
            return
        }

        if rawText.isEmpty {
            if let errorMessage, punctuation?.isEmpty ?? true {
                finishPresentation(request: request, errorMessage: errorMessage, errorDismissAfter: 5)
                return
            }

            deliverPunctuationOnlyAndFinish(punctuation, request: request)
            return
        }

        let processedText = processedTextForFinalResult(rawText, isImmediateFinish: true, request: request)
        let finalText = textByAppendingImmediatePunctuation(punctuation, to: processedText)

        deliverAndFinish(finalText, request: request)
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
        let processedText = request.preparedText ?? textPostProcessorRegistry.run(rawText, context: context)
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

    func remainingTextAfterLiveInsertion(
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
        let safeSuffixStart = liveInsertionSuffixStartIndex(in: text, commonPrefixEnd: commonPrefixEnd)
        let commonPrefixLength = text.distance(from: text.startIndex, to: safeSuffixStart)
        if commonPrefixLength > 0 {
            DebugLog.info("[LiveInsertion] Final text differs from committed prefix, injecting from common-prefix suffix")
            return String(text[safeSuffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        DebugLog.info("[LiveInsertion] Final text does not match committed prefix, injecting full final text to avoid dropped characters")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func liveInsertionSuffixStartIndex(in text: String, commonPrefixEnd: String.Index) -> String.Index {
        guard commonPrefixEnd > text.startIndex, commonPrefixEnd < text.endIndex else {
            return commonPrefixEnd
        }

        let previous = text[text.index(before: commonPrefixEnd)]
        let next = text[commonPrefixEnd]
        guard previous.isASCII,
              next.isASCII,
              (previous.isLetter || previous.isNumber),
              (next.isLetter || next.isNumber) else {
            return commonPrefixEnd
        }

        var index = commonPrefixEnd
        while index > text.startIndex {
            let previousIndex = text.index(before: index)
            let character = text[previousIndex]
            if character.isWhitespace || PunctuationProcessor.isUserTypedPunctuation(character) {
                return index
            }
            index = previousIndex
        }

        return text.startIndex
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

    private func showRecordingResultErrorOrDismiss(_ errorMessage: String?, request: Request) {
        finishPresentation(request: request, errorMessage: errorMessage, errorDismissAfter: 5)
    }

    private func cancelStreamingResult(
        _ session: TextStreamSession,
        errorMessage: String?,
        request: Request
    ) {
        session.cancel()
        request.clearStreamSession()
        showRecordingResultErrorOrDismiss(errorMessage, request: request)
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
            finishPresentation(request: request, errorMessage: errorMessage, errorDismissAfter: 5)
            return
        }
        deliverPunctuationOnlyAndFinish(punctuation, request: request)
    }

    private func finalizeStreamSession(
        _ session: TextStreamSession,
        replacingWith replacement: String?,
        request: Request,
        errorMessage: String? = nil
    ) {
        guard isGenerationValid(request.generation) else { return }
        var didComplete = false
        session.finalize(replacingWith: replacement) { [weak self] in
            guard let self, self.isGenerationValid(request.generation), !didComplete else { return }
            didComplete = true
            request.clearStreamSession()
            if let errorMessage {
                self.finishPresentation(request: request, errorMessage: errorMessage)
            } else {
                // 流式端可能尚未提交最终替换；保留至 finalize 完成，再立即让开。
                self.dismissSuccessfulResult(request: request)
            }
        }
    }

    private func deliverAndFinish(_ text: String, request: Request, errorMessage: String? = nil) {
        guard isGenerationValid(request.generation) else { return }
        // 文字先进入独立输出队列，成功胶囊立即让开；剪贴板保护不依赖 UI 生命周期。
        var didComplete = false
        outputSinkProvider().deliver(text: text) { [weak self] in
            guard let self, self.isGenerationValid(request.generation), !didComplete else { return }
            didComplete = true
            if let errorMessage {
                self.finishPresentation(request: request, errorMessage: errorMessage)
            }
        }
        if errorMessage == nil { dismissSuccessfulResult(request: request) }
    }

    private func deliverPunctuationOnlyAndFinish(_ punctuation: String?, request: Request) {
        if let punctuation, !punctuation.isEmpty {
            deliverAndFinish(punctuation, request: request)
        } else {
            finishPresentation(request: request, errorMessage: nil)
        }
    }

    private func dismissSuccessfulResult(request: Request) {
        // 输出端可能同步回调并开启新一轮，提交后再次核对，不能隐藏新胶囊。
        guard isGenerationValid(request.generation) else { return }
        presenter.dismissRecognitionImmediately()
    }

    private func finishPresentation(request: Request, errorMessage: String?, errorDismissAfter: TimeInterval = 3) {
        guard let errorMessage else {
            dismissSuccessfulResult(request: request)
            return
        }
        // 错误仍等既有输出事务收尾后展示；成功不等待旧实时粘贴、清理或结果展示延迟。
        request.waitForPriorOutput { [weak self] in
            guard let self, self.isGenerationValid(request.generation) else { return }
            self.presenter.showRecognitionError(errorMessage, dismissAfter: errorDismissAfter)
        }
    }
}
