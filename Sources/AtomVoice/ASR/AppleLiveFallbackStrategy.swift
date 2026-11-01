import AVFoundation
import Foundation
import Speech

/// 豆包识别失败后启动 Apple 实时识别回退的策略对象。
/// (Strategy that activates Apple live recognition as a fallback after Doubao recognition fails.)
///
/// 职责：
/// - 判断豆包错误是否属于"长按不说话"静音误报（应被静默吞掉）。
/// - 启动 SFSpeechRecognizer，绑定到当前 AudioEngine 上接收实时音频。
/// - 不持有胶囊 / 录音 generation / streamSession 等编排状态——这些归 AppDelegate（未来 RecordingSessionController）。
final class AppleLiveFallbackStrategy {
    private let audioEngine: AudioEngineController
    private let audioFormat: AudioRouter.ConsumerFormat
    private let fallback: DoubaoFallbackCoordinator
    private let speechRecognizerProvider: () -> SpeechRecognizerController

    init(audioEngine: AudioEngineController,
         fallback: DoubaoFallbackCoordinator,
         audioFormat: AudioRouter.ConsumerFormat = .voice16k,
         speechRecognizerProvider: @escaping () -> SpeechRecognizerController) {
        self.audioEngine = audioEngine
        self.fallback = fallback
        self.audioFormat = audioFormat
        self.speechRecognizerProvider = speechRecognizerProvider
    }

    /// 判断豆包错误是否属于"长按不说话"误报：录音中无任何识别文本时的 Socket 未连接错误。
    /// (Whether the Doubao error is a benign "user held the trigger silently" socket-disconnect false positive.)
    func isBenignSilenceError(_ failure: CloudASRFailure, cloudCurrentText: String) -> Bool {
        guard cloudCurrentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fallback.liveDisplayText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        return failure.isBenignSocketClosure
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
            onError: { error in
                DebugLog.error("[AppleLiveFallback] \(error)")
            },
            onRequestSwitch: { [weak self] newRequest in
                // 续录沿用云端采集配置（豆包仍为 16kHz），与初次接入和回灌一致。
                self?.audioEngine.switchRequest(newRequest, format: self?.audioFormat)
            }
        )

        if let request {
            // 先把豆包断流前最近几秒的回看音频回灌给 Apple，补回"豆包已收音但识别结果未回传"的
            // 交接缺口；再按同一配置接实时流，重叠去重交给 combinedText。
            for buffer in fallback.rollingBufferSnapshot() {
                request.append(buffer)
            }
            audioEngine.switchRequest(request, format: audioFormat)
        }
        return initialText
    }
}
