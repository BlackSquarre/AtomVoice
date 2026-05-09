import Foundation

/// 豆包识别失败后启动 Apple 实时识别回退的策略对象。
/// (Strategy that activates Apple live recognition as a fallback after Doubao recognition fails.)
///
/// 职责：
/// - 判断豆包错误是否属于"长按不说话"静音误报（应被静默吞掉）。
/// - 启动 SFSpeechRecognizer，绑定到当前 AudioEngine 上接收实时音频。
/// - 不持有胶囊 / 录音 generation / streamSession 等编排状态——这些归 AppDelegate（未来 RecordingSessionController）。
final class AppleLiveFallbackStrategy {
    private let audioEngine: AudioEngineController
    private let fallback: DoubaoFallbackCoordinator
    private let speechRecognizerProvider: () -> SpeechRecognizerController

    init(audioEngine: AudioEngineController,
         fallback: DoubaoFallbackCoordinator,
         speechRecognizerProvider: @escaping () -> SpeechRecognizerController) {
        self.audioEngine = audioEngine
        self.fallback = fallback
        self.speechRecognizerProvider = speechRecognizerProvider
    }

    /// 判断豆包错误是否属于"长按不说话"误报：录音中无任何识别文本时的 Socket 未连接错误。
    /// (Whether the Doubao error is a benign "user held the trigger silently" socket-disconnect false positive.)
    func isBenignSilenceError(_ message: String, cloudCurrentText: String) -> Bool {
        guard cloudCurrentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fallback.liveDisplayText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        let lowercased = message.lowercased()
        return lowercased.contains("socket") && (
            lowercased.contains("not connected") ||
            lowercased.contains("未连接") ||
            lowercased.contains("未能完成")
        )
    }

    /// 启动 Apple 实时回退识别。
    /// 已激活时返回 nil；否则返回胶囊应当首次展示的文本（云端前缀 + 错误提示 / 引擎名）。
    /// `onPartial` 在主线程触发，传入合并后的展示文本（云端前缀 + Apple 实时识别）。
    /// (Returns nil if already active. Otherwise returns the initial text to show on the capsule;
    ///  onPartial fires on main with merged "cloud-prefix + Apple-live" text.)
    func engage(onPartial: @escaping (_ mergedText: String) -> Void) -> String? {
        guard !fallback.isAppleLiveActive else { return nil }

        let errorHint = fallback.beginAppleLiveFallback() ?? ""
        let liveDisplayText = fallback.liveDisplayText()
        let fallbackText = errorHint.isEmpty
            ? loc("menu.recognitionEngine.apple")
            : loc("doubao.fallback.withError", errorHint)
        let initialText = liveDisplayText.isEmpty ? fallbackText : liveDisplayText

        let request = speechRecognizerProvider().start(
            onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    guard let self, self.fallback.isAppleLiveActive else { return }
                    onPartial(self.fallback.liveDisplayText(liveText: text))
                }
            },
            onRequestSwitch: { [weak self] newRequest in
                self?.audioEngine.switchRequest(newRequest)
            }
        )

        if let request {
            audioEngine.switchRequest(request)
        }
        return initialText
    }
}
