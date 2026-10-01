import Cocoa
import Carbon

final class TextInjector {
    private struct PendingInjection {
        let text: String
        let completion: (() -> Void)?
    }

    private static let injectionWatchdogTimeout: TimeInterval = 5.0
    private static let pasteboardSnapshotTimeout: TimeInterval = 2.0
    // Cmd+V 只是把事件投递给目标应用；低配机器或被系统调度的应用可能在事件发送后
    // 才真正读取剪贴板。恢复过早会让目标应用读到恢复前的旧内容，表现为粘贴上一条剪切板。
    // (Paste is asynchronous. Keep the injected value alive after the event so a busy target
    // cannot read the restored, stale clipboard contents.)
    private static let postPasteReadGrace: TimeInterval = 0.75

    private var pendingInjections: [PendingInjection] = []
    private var lifecycle = TextInjectionLifecycle()
    private var activeTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private let pasteboardService: PasteboardServicing

    init(pasteboardService: PasteboardServicing = SystemPasteboardService()) {
        self.pasteboardService = pasteboardService
    }

    func inject(text: String, completion: (() -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [self] in
                inject(text: text, completion: completion)
            }
            return
        }

        pendingInjections.append(PendingInjection(text: text, completion: completion))
        processNextInjection()
    }

    private func processNextInjection() {
        guard !lifecycle.isActive, !pendingInjections.isEmpty else { return }

        let next = pendingInjections.removeFirst()
        guard !next.text.isEmpty else {
            next.completion?()
            processNextInjection()
            return
        }

        let injectionID = UUID()
        lifecycle.start(id: injectionID)
        let text = next.text
        let completion = next.completion

        // 主任务：跑完整粘贴流程，结束后在主线程上回收状态并推进队列。
        // (Main task: run the full paste pipeline, then reconcile state on main thread.)
        activeTask = Task { @MainActor [weak self] in
            await self?.performInject(text: text, injectionID: injectionID)
            self?.finishInjection(injectionID: injectionID, completion: completion)
        }

        // Watchdog 只取消尚未改写剪贴板的任务；提交后必须等待恢复完成，避免新旧注入交叉。
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.injectionWatchdogTimeout * 1_000_000_000))
            self?.handleWatchdog(injectionID: injectionID, textLength: text.count, completion: completion)
        }
    }

    @MainActor
    private func finishInjection(injectionID: UUID, completion: (() -> Void)?) {
        guard lifecycle.finish(id: injectionID) else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        activeTask = nil
        completion?()
        processNextInjection()
    }

    @MainActor
    private func handleWatchdog(injectionID: UUID, textLength: Int, completion: (() -> Void)?) {
        switch lifecycle.handleTimeout(id: injectionID) {
        case .cancel:
            DebugLog.error("[TextInjector] Injection timed out before clipboard commit after \(Self.injectionWatchdogTimeout)s, textLength=\(textLength)")
            activeTask?.cancel()
            activeTask = nil
            watchdogTask = nil
            completion?()
            processNextInjection()
        case .waitForCleanup:
            DebugLog.error("[TextInjector] Injection exceeded \(Self.injectionWatchdogTimeout)s after clipboard commit; waiting for cleanup, textLength=\(textLength)")
            watchdogTask = nil
        case .stale:
            break
        }
    }

    @MainActor
    private func performInject(text: String, injectionID: UUID) async {
        // 在主线程上读取前台应用的 bundleID，命中内置兼容性清单时改用更长的粘贴延迟，避免远程桌面/虚拟机/串流类应用丢字符。
        // (Resolve frontmost app on main thread to pick per-app paste delay override for remote desktop / VM / streaming clients.)
        let compatProfile: PasteCompatibilityProfile? = PasteCompatibilityRegistry.profileForFrontmostApp()
        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetPID = targetApp?.processIdentifier
        let targetBundleID = targetApp?.bundleIdentifier ?? "unknown"
        let targetPIDDescription = targetPID.map { String($0) } ?? "nil"
        let nativePastePID = BrowserPasteCompatibility.usesNativePaste(bundleID: targetApp?.bundleIdentifier)
            ? targetApp?.processIdentifier : nil

        DebugLog.info("[TextInjector] begin id=\(injectionID.uuidString) textLength=\(text.count) target=\(targetBundleID) pid=\(targetPIDDescription)")

        // 将获取光标后字符的跨进程 IPC 调用移至后台 Task，避免目标应用挂起时连带卡死主线程。
        let nextChar = await Task.detached(priority: .userInitiated) {
            Self.getCharacterAfterCursor()
        }.value
        let pasteMenuItem = await Task.detached(priority: .userInitiated) {
            nativePastePID.flatMap { BrowserPasteCompatibility.pasteMenuItem(processID: $0) }
        }.value
        guard !Task.isCancelled,
              lifecycle.transition(id: injectionID, from: .preparing, to: .snapshotting) else {
            return
        }

        var finalText = text
        if let nextChar, PunctuationProcessor.isSentenceEndingPunctuation(nextChar) {
            finalText = Self.removeTrailingPunctuation(text)
        }

        let captureResult = await pasteboardService.capture(timeout: Self.pasteboardSnapshotTimeout)
        guard !Task.isCancelled, lifecycle.isCurrent(injectionID) else { return }
        guard case .captured(let snapshot) = captureResult else {
            logCaptureFailure(captureResult)
            return
        }

        guard Self.frontmostProcessID() == targetPID else {
            DebugLog.error("[TextInjector] Frontmost app changed before clipboard write; cancelling injection id=\(injectionID.uuidString)")
            return
        }
        DebugLog.debug("[TextInjector] Clipboard captured id=\(injectionID.uuidString) changeCount=\(snapshot.changeCount)")

        // 从这里开始剪贴板可能被改写，不能再由 watchdog 直接推进下一项。
        guard lifecycle.transition(id: injectionID, from: .snapshotting, to: .committing) else { return }
        let writeResult = await pasteboardService.write(
            text: finalText,
            replacing: snapshot
        )
        guard lifecycle.isCurrent(injectionID) else { return }
        guard case .written(let injectedChangeCount) = writeResult else {
            DebugLog.error("[TextInjector] Clipboard changed or could not be written before paste")
            return
        }
        DebugLog.debug("[TextInjector] Clipboard committed id=\(injectionID.uuidString) changeCount=\(injectedChangeCount)")

        // 检查当前输入源是否为 CJK，如需要则切换到 ASCII（Check current input source, switch to ASCII if needed）
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needsSwitch = Self.isCJKInputSource(originalSource)
        if needsSwitch {
            Self.switchToASCIIInputSource()
        }

        // 短暂等待输入源切换生效（Wait briefly for input source switch to take effect）
        await Self.sleep(seconds: needsSwitch ? 0.05 : 0.02)
        guard lifecycle.isCurrent(injectionID) else { return }
        guard Self.frontmostProcessID() == targetPID else {
            DebugLog.error("[TextInjector] Frontmost app changed before paste; restoring without posting event id=\(injectionID.uuidString)")
            let restoreResult = await pasteboardService.restore(
                snapshot,
                expectedChangeCount: injectedChangeCount
            )
            if case .failed = restoreResult {
                DebugLog.error("[TextInjector] Failed to restore clipboard after target change id=\(injectionID.uuidString)")
            }
            return
        }
        if let pasteMenuItem {
            // 原生菜单触发 DOM paste，不经过网页 keydown 的快捷键拦截。
            // 焦点已换到别的应用时不向原应用投递；后续仍恢复剪贴板和输入法。
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == nativePastePID {
                let status = await Task.detached(priority: .userInitiated) {
                    AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString)
                }.value
                if status != .success {
                    // 超时不代表没有执行，不能再发送 Command+V，以免重复写入。
                    DebugLog.error("[TextInjector] Native browser paste failed status=\(status.rawValue)")
                }
                DebugLog.debug("[TextInjector] Native paste event posted id=\(injectionID.uuidString)")
            }
        } else {
            Self.simulatePaste()
            DebugLog.debug("[TextInjector] Cmd+V event posted id=\(injectionID.uuidString)")
        }

        // 粘贴延迟：给目标 App（含 Electron 等慢应用）足够时间完成粘贴；debug build 可在菜单调节。
        // 远程桌面 / 虚拟机 / 串流类应用命中兼容性清单时使用更长的延迟，避免键盘转发掉字符。
        // (Paste delay: enough time for target apps incl. Electron; tunable via debug menu.
        //  Remote-desktop / VM / streaming clients matched by compatibility registry use a longer override to avoid dropped characters.)
        let pasteDelay = max(AppSettings.pasteDelay, compatProfile?.pasteDelay ?? 0)
        await Self.sleep(seconds: pasteDelay)
        guard lifecycle.isCurrent(injectionID) else { return }

        if needsSwitch {
            TISSelectInputSource(originalSource)
        }

        // 再留出一段读取窗口后恢复剪贴板。单等一帧在低配机器上不够：Cmd+V 事件可能
        // 尚未被目标应用处理，过早恢复会把旧剪贴板内容粘进去。
        // (Allow a real read window before restoring; one run-loop frame is insufficient on slow machines.)
        let readGrace = max(Self.postPasteReadGrace, (compatProfile?.pasteDelay ?? 0) * 1.5)
        await Self.sleep(seconds: readGrace)
        guard lifecycle.transition(id: injectionID, from: .committing, to: .restoring) else { return }
        let restoreResult = await pasteboardService.restore(
            snapshot,
            expectedChangeCount: injectedChangeCount
        )
        if case .failed = restoreResult {
            DebugLog.error("[TextInjector] Failed to restore clipboard contents")
        } else {
            DebugLog.debug("[TextInjector] Clipboard restored id=\(injectionID.uuidString) result=\(String(describing: restoreResult))")
        }
    }

    private func logCaptureFailure(_ result: PasteboardCaptureResult) {
        switch result {
        case .captured:
            break
        case .timedOut:
            DebugLog.error("[TextInjector] Clipboard snapshot timed out; paste was cancelled")
        case .busy:
            DebugLog.error("[TextInjector] Clipboard snapshot worker is still busy; paste was cancelled")
        case .changed:
            DebugLog.error("[TextInjector] Clipboard changed while taking a snapshot; paste was cancelled")
        }
    }

    private static func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: - 光标标点检测

    /// 获取当前聚焦输入框中光标后方的第一个字符（Get the first character after cursor in the currently focused text field）
    private static func getCharacterAfterCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()

        // 获取当前聚焦的 UI 元素（Get the currently focused UI element）
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focusedElement = focused else { return nil }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        let focusedUIElement = focusedElement as! AXUIElement

        // 获取选区范围（光标位置）（Get selection range / cursor position）
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focusedUIElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success, let range = selectedRange else { return nil }

        guard CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        let axValue = range as! AXValue
        var rangeValue = CFRange()
        AXValueGetValue(axValue, .cfRange, &rangeValue)

        // 获取输入框文本内容（Get text field content）
        var value: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(focusedUIElement, kAXValueAttribute as CFString, &value)
        guard textResult == .success, let text = value as? String else { return nil }

        // 计算光标后方位置（Calculate position after cursor）
        // AX API 的 CFRange 使用 UTF-16 偏移，需用 UTF16View 索引（AX API's CFRange uses UTF-16 offsets, must use UTF16View indexing）
        let utf16 = text.utf16
        let nextIndex = rangeValue.location + rangeValue.length
        guard nextIndex >= 0, nextIndex < utf16.count else { return nil }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: nextIndex)
        guard let charIndex = utf16Index.samePosition(in: text) else { return nil }
        return text[charIndex]
    }

    /// 移除文本末尾的标点符号（Remove trailing punctuation from text）
    private static func removeTrailingPunctuation(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, PunctuationProcessor.isSentenceEndingPunctuation(last) {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func isCJKInputSource(_ source: TISInputSource) -> Bool {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

        let cjkPatterns = [
            "com.apple.inputmethod.SCIM",   // 简体中文（Simplified Chinese）
            "com.apple.inputmethod.TCIM",   // 繁体中文（Traditional Chinese）
            "com.apple.inputmethod.Japanese",// 日文（Japanese）
            "com.apple.inputmethod.Korean",  // 韩文（Korean）
            "com.apple.inputmethod.ChineseHandwriting",// 中文手写（Chinese Handwriting）
            "com.google.inputmethod.Japanese",// 日文（Japanese）
            "com.sogou.inputmethod",
            "com.baidu.inputmethod",
            "com.tencent.inputmethod",
        ]

        return cjkPatterns.contains(where: { sourceID.hasPrefix($0) })
    }

    private static func switchToASCIIInputSource() {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout,
        ] as CFDictionary

        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        // 优先选择 ABC 或 US 键盘布局（Prefer ABC or US keyboard layout）
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for prefID in preferred {
            if let source = sources.first(where: { source in
                guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                return id == prefID
            }) {
                TISSelectInputSource(source)
                return
            }
        }

        // 回退：选择第一个支持 ASCII 的键盘布局 (Fallback: select first ASCII-capable keyboard layout)
        if let asciiCapableSource = sources.first(where: { source in
            guard let capablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
            return Unmanaged<CFBoolean>.fromOpaque(capablePtr).takeUnretainedValue() == kCFBooleanTrue
        }) {
            TISSelectInputSource(asciiCapableSource)
            return
        }

        // 最终回退：选择第一个可用的输入源（Fallback: select first available source）
        if let first = sources.first {
            TISSelectInputSource(first)
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V 键（V key）
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

}
