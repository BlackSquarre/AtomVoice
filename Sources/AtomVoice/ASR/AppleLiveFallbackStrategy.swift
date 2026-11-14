import AVFoundation
import Foundation
import Speech

/// 云端识别失败后复用同一 Apple owner 接收缓存及后续实时音频。
///
/// 职责：
/// - 判断豆包错误是否属于"长按不说话"静音误报（应被静默吞掉）。
/// - 启动 SFSpeechRecognizer，在本轮输入队列中有序回灌并接收后续音频。
/// - 不持有胶囊 / 录音 generation / streamSession，编排由 RecordingSessionController 承担。
final class AppleLiveFallbackStrategy {
    private let fallback: DoubaoFallbackCoordinator
    private let speechRecognizerProvider: () -> any AppleSpeechRecognizing
    private let fallbackErrorKey: String

    init(fallback: DoubaoFallbackCoordinator,
         fallbackErrorKey: String = "doubao.fallback.withError",
         speechRecognizerProvider: @escaping () -> any AppleSpeechRecognizing) {
        self.fallback = fallback
        self.fallbackErrorKey = fallbackErrorKey
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
    func engage(audioInput: RecordingAudioInput,
                onPartial: @escaping (_ mergedText: String) -> Void) -> String? {
        guard !fallback.isAppleLiveActive else { return nil }

        let errorHint = fallback.beginAppleLiveFallback() ?? ""
        let liveDisplayText = fallback.liveDisplayText()
        let fallbackText = errorHint.isEmpty
            ? loc("menu.recognitionEngine.apple")
            : loc(fallbackErrorKey, errorHint)
        let initialText = liveDisplayText.isEmpty ? fallbackText : liveDisplayText

        let request = speechRecognizerProvider().start(
            onResult: { [weak self] text, _ in
                DispatchQueue.main.async {
                    guard let self, self.fallback.isAppleLiveActive else { return }
                    onPartial(self.fallback.liveDisplayText(liveText: text))
                }
            },
            onError: { _ in
                DebugLog.error("[AppleLiveFallback] Recognition failed")
            },
            onRequestSwitch: { [weak self] newRequest in
                // 沿用本轮输入格式和队列，不另注册第二条 Router 消费者。
                audioInput.connect { [weak self] buffer in
                    guard self?.fallback.isAppleLiveActive == true else { return }
                    newRequest.append(buffer)
                }
            }
        )

        if let request {
            // 快照与目的地切换在原输入队列中排序：此前帧先缓存，此后帧紧接回放。
            audioInput.connect(replaying: { [weak self] in
                guard let self, self.fallback.isAppleLiveActive else { return [] }
                return self.fallback.liveReplayBuffers()
            }) { [weak self] buffer in
                guard self?.fallback.isAppleLiveActive == true else { return }
                request.append(buffer)
            }
        }
        return initialText
    }
}
