import AVFoundation

/// Sherpa 模型预加载协调器：模型未加载时缓存音频，加载完成后排空缓冲并切换到直推模式。
/// (Sherpa preload coordinator: buffers audio while model is loading, then drains and hands off to live mode.)
///
/// 关键策略（来自 BUG-7 修复）：
/// 1. 排空在串行 queue 上执行，保证缓冲音频按顺序投递。
/// 2. 二次排空：首次排空把 `isActive` 切到 false 后，audio 线程仍可能在缓冲读到旧值的瞬间往 buffers 里写入零星帧，
///    再 enqueue 一次清空任务捕获这部分 stragglers，避免丢字。
final class SherpaPreloadCoordinator {
    private let queue = DispatchQueue(label: "com.atomvoice.sherpaPreload")
    private var buffers: [AVAudioPCMBuffer] = []
    private var isActive = false

    /// 标记预加载开始，清空残留缓冲（Mark preload as active and clear any residual buffers）
    func begin() {
        queue.sync {
            isActive = true
            buffers.removeAll(keepingCapacity: false)
        }
    }

    /// 处于预加载阶段时缓存音频；返回 true 表示已被本协调器接管，调用方应 *不* 再直推识别器。
    /// (When active, buffer the audio and return true so the caller skips the live path.)
    @discardableResult
    func appendIfActive(_ buffer: AVAudioPCMBuffer,
                        copyBuffer: (AVAudioPCMBuffer) -> AVAudioPCMBuffer?) -> Bool {
        queue.sync {
            guard isActive else { return false }
            guard let copy = copyBuffer(buffer) else { return true }
            buffers.append(copy)
            return true
        }
    }

    /// 模型加载成功后排空全部缓冲；含二次排空。`onComplete` 在二次排空完成后回调（在内部 queue 上下文，调用方自行切回主线程）。
    /// (Drain all buffered audio after model load. Second drain captures stragglers; onComplete fires on the internal queue.)
    func drain(accept: @escaping (AVAudioPCMBuffer) -> Void,
               onComplete: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let buffered = self.buffers
            self.buffers = []
            self.isActive = false

            for buf in buffered {
                accept(buf)
            }

            // 二次排空：处理 flag 切换瞬间积压的零星缓冲（Second drain for stragglers during flag transition）
            self.queue.async { [weak self] in
                guard let self else { return }
                let stragglers = self.buffers
                self.buffers = []
                for buf in stragglers {
                    accept(buf)
                }
                onComplete()
            }
        }
    }

    /// 取消预加载并清空缓冲（Cancel preload and clear buffers）
    func cancel() {
        queue.sync {
            isActive = false
            buffers.removeAll(keepingCapacity: false)
        }
    }
}
