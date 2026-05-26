import Cocoa
import Carbon

// 文本输出端描述：用于菜单展示与能力查询
// (Text output sink descriptor: used for menu display and capability queries)
struct TextOutputSinkDescriptor {
    let code: String
    let displayNameKey: String
    let iconName: String
    /// 是否支持流式增量上屏（对应"流式直接上屏"模式）
    /// (Whether the sink supports streaming incremental on-screen output)
    let supportsStreaming: Bool
}

// 流式会话：从录音开始到结束，由 sink 持有；管理已上屏文本的范围与替换
// (Streaming session: held by the sink from recording start to finish; tracks on-screen range and replacement)
protocol TextStreamSession: AnyObject {
    /// 喂入 ASR 当前完整文本（不是增量），由 session 自己算 delta
    /// (Feed the current full text from ASR — the session computes the delta itself)
    func update(currentText: String)
    /// 录音结束。replacingWith 非 nil 时把已上屏内容整体替换为 finalText（LLM 优化的结果）
    /// (Recording finished. If replacingWith is non-nil, replace all on-screen content with finalText — LLM result)
    func finalize(replacingWith finalText: String?, completion: (() -> Void)?)
    /// 取消并清理状态（不撤销已上屏文字）
    /// (Cancel and clear state — does not undo already on-screen text)
    func cancel()
}

// 文本输出端协议
// (Text output sink protocol)
protocol TextOutputSink: AnyObject {
    var descriptor: TextOutputSinkDescriptor { get }
    /// 一次性投递（粘贴模式使用）
    /// (One-shot delivery — used by paste mode)
    func deliver(text: String, completion: (() -> Void)?)
    /// 创建流式会话；不支持流式或当前环境不可用时返回 nil
    /// (Create a streaming session; nil if streaming unsupported or not available right now)
    func beginStream() -> TextStreamSession?
}

extension TextOutputSink {
    func beginStream() -> TextStreamSession? { nil }
}

// 输出端注册中心
// (Output sink registry)
final class TextOutputSinkRegistry {
    static let pasteCode = "paste"
    static let streamingCode = "streaming"
    static let settingsKey = AppSettings.Keys.textOutputSink

    let sinks: [TextOutputSink]
    private let sinkByCode: [String: TextOutputSink]
    private let fallbackCode: String

    init(sinks: [TextOutputSink], fallbackCode: String = TextOutputSinkRegistry.pasteCode) {
        precondition(!sinks.isEmpty)
        self.sinks = sinks
        self.fallbackCode = fallbackCode
        self.sinkByCode = Dictionary(uniqueKeysWithValues: sinks.map { ($0.descriptor.code, $0) })
    }

    var descriptors: [TextOutputSinkDescriptor] { sinks.map { $0.descriptor } }

    func sink(for code: String) -> TextOutputSink {
        sinkByCode[code] ?? sinkByCode[fallbackCode] ?? sinks[0]
    }

    func currentCode() -> String {
        let raw = AppSettings.backend.string(forKey: Self.settingsKey) ?? fallbackCode
        return sinkByCode[raw] != nil ? raw : fallbackCode
    }

    func current() -> TextOutputSink {
        sink(for: currentCode())
    }
}

// MARK: - 粘贴注入（一次性，原有行为）
// (Paste injection — one-shot, preserves original behavior)

final class PasteboardInjectSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(
        code: TextOutputSinkRegistry.pasteCode,
        displayNameKey: "menu.textOutput.paste",
        iconName: "doc.on.clipboard",
        supportsStreaming: false
    )

    private let injector: TextInjector

    init(injector: TextInjector) {
        self.injector = injector
    }

    func deliver(text: String, completion: (() -> Void)?) {
        injector.inject(text: text, completion: completion)
    }
}

// MARK: - 流式直接上屏（AX 优先 + Paste 兜底）
// (Streaming direct-to-screen — AX preferred, paste fallback)

final class StreamingInjectSink: TextOutputSink {
    let descriptor = TextOutputSinkDescriptor(
        code: TextOutputSinkRegistry.streamingCode,
        displayNameKey: "menu.textOutput.streaming",
        iconName: "text.cursor",
        supportsStreaming: true
    )

    private let injector: TextInjector

    init(injector: TextInjector) {
        self.injector = injector
    }

    /// 录音开始时调用，依据当前聚焦元素的 AX 写能力一次性决定路径
    /// (Called at recording start; the path is decided once based on the focused element's AX writability)
    func beginStream() -> TextStreamSession? {
        if AXTextWriter.canWriteFocusedElement(), let session = AXStreamSession() {
            return session
        }
        return PasteStreamSession(injector: injector)
    }

    /// 流式 sink 的"一次性投递"路径：仅在外部直接调用 deliver 时（少见）走 paste 兜底
    /// (One-shot path of the streaming sink: only used if deliver is called directly — paste fallback)
    func deliver(text: String, completion: (() -> Void)?) {
        injector.inject(text: text, completion: completion)
    }
}

// MARK: - AX 流式会话
// (AX streaming session)

private final class AXStreamSession: TextStreamSession {
    /// 录音开始时光标的位置（UTF-16）
    /// (Caret location in UTF-16 at recording start)
    private let baseLocation: Int
    /// 已上屏文本（自录音开始至今我们写入的内容）
    /// (Text we have written on-screen since recording started)
    private var insertedText: String = ""

    init?() {
        // 先记下基准光标位置；拿不到就算了（理论上 canWriteFocusedElement 已通过）
        // (Record baseline caret location; bail if unavailable — should not happen if writability passed)
        guard let location = AXTextWriter.currentCaretLocation() else { return nil }
        self.baseLocation = location
    }

    func update(currentText: String) {
        if Thread.isMainThread {
            applyUpdate(currentText: currentText)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyUpdate(currentText: currentText) }
        }
    }

    private func applyUpdate(currentText: String) {
        // 求与已上屏文本的最长公共前缀；前缀之后的部分是需要替换的差异
        // (Find longest common prefix; the suffix beyond it is the diff to replace)
        let common = commonPrefix(insertedText, currentText)
        let staleSuffixLen = insertedText.utf16.count - common.utf16.count
        let newSuffix = String(currentText[common.endIndex(in: currentText)...])

        if staleSuffixLen == 0 && newSuffix.isEmpty { return }

        let replaceStart = baseLocation + common.utf16.count
        if staleSuffixLen > 0 {
            _ = AXTextWriter.replaceRange(location: replaceStart, length: staleSuffixLen, with: newSuffix)
        } else {
            _ = AXTextWriter.insertAtCaret(newSuffix)
        }
        insertedText = currentText
    }

    func finalize(replacingWith finalText: String?, completion: (() -> Void)?) {
        let work = { [self] in
            if let finalText, finalText != insertedText {
                _ = AXTextWriter.replaceRange(
                    location: baseLocation,
                    length: insertedText.utf16.count,
                    with: finalText
                )
                insertedText = finalText
            }
            completion?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func cancel() {
        // 不撤销已上屏文字，仅丢弃状态（与 Apple live insertion 一致）
        // (Do not undo on-screen text; just drop state — consistent with Apple live insertion)
        insertedText = ""
    }
}

// MARK: - Paste 兜底流式会话
// (Paste fallback streaming session)

private final class PasteStreamSession: TextStreamSession {
    private let injector: TextInjector
    private var insertedText: String = ""
    /// 串行化粘贴/退格事件，避免重叠（Serialize paste/backspace events to avoid overlap）
    private var operationInFlight = false
    private var pendingTarget: String?

    init(injector: TextInjector) {
        self.injector = injector
    }

    func update(currentText: String) {
        let work = { [self] in
            pendingTarget = currentText
            drainIfIdle()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func drainIfIdle() {
        guard !operationInFlight, let target = pendingTarget else { return }
        pendingTarget = nil
        let common = commonPrefix(insertedText, target)
        // 退格键按 grapheme cluster（Character）删除，不是 UTF-16 code unit。
        // 用 .count 避免 emoji / 增补 CJK 字符被多删。
        // (Backspace deletes by grapheme cluster, not UTF-16 code unit.
        //  Use .count to avoid over-deleting emoji / supplementary CJK characters.)
        let staleSuffixLen = insertedText.count - common.count
        let newSuffix = String(target[common.endIndex(in: target)...])

        if staleSuffixLen == 0 && newSuffix.isEmpty {
            return
        }

        operationInFlight = true
        if staleSuffixLen > 0 {
            sendBackspaces(staleSuffixLen) { [weak self] in
                guard let self else { return }
                if newSuffix.isEmpty {
                    self.insertedText = String(self.insertedText.prefix(common.count))
                    self.operationInFlight = false
                    self.drainIfIdle()
                    return
                }
                self.injector.inject(text: newSuffix) { [weak self] in
                    guard let self else { return }
                    self.insertedText = target
                    self.operationInFlight = false
                    self.drainIfIdle()
                }
            }
        } else {
            injector.inject(text: newSuffix) { [weak self] in
                guard let self else { return }
                self.insertedText = target
                self.operationInFlight = false
                self.drainIfIdle()
            }
        }
    }

    func finalize(replacingWith finalText: String?, completion: (() -> Void)?) {
        guard let finalText, finalText != insertedText else {
            completion?()
            return
        }
        // 把替换走 update 通道：pendingTarget 设为 finalText，drain 时会算 diff 自动退格+粘贴
        // (Route replacement through the update channel: set pendingTarget = finalText, drain will diff & replace)
        pendingTarget = finalText
        if operationInFlight {
            // drainIfIdle 在当前操作完成回调里会再次触发；用一个 polling 等流空再 completion
            // (drainIfIdle is re-triggered in the completion of the current operation; poll until idle then call completion)
            waitUntilIdle(completion: completion)
        } else {
            drainIfIdle()
            waitUntilIdle(completion: completion)
        }
    }

    private func waitUntilIdle(completion: (() -> Void)?) {
        if !operationInFlight && pendingTarget == nil {
            completion?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilIdle(completion: completion)
        }
    }

    func cancel() {
        pendingTarget = nil
        insertedText = ""
    }

    /// 模拟 N 次退格（每次 keyDown+keyUp，间隔很小避免目标 App 漏键）
    /// (Simulate N backspace presses with a tiny gap to avoid the target app dropping keys)
    private func sendBackspaces(_ count: Int, completion: @escaping () -> Void) {
        guard count > 0 else { completion(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            for _ in 0..<count {
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)  // Delete/Backspace
                let up   = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.002)
            }
            DispatchQueue.main.async { completion() }
        }
    }
}

// MARK: - 共享：求最长公共前缀（按 Character 分割，兼顾多字节字符）
// (Shared: longest common prefix split by Character for multi-byte safety)

private func commonPrefix(_ a: String, _ b: String) -> String {
    var ai = a.startIndex
    var bi = b.startIndex
    while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
        ai = a.index(after: ai)
        bi = b.index(after: bi)
    }
    return String(a[..<ai])
}

private extension String {
    func endIndex(in other: String) -> String.Index {
        other.index(other.startIndex, offsetBy: self.count)
    }
}
