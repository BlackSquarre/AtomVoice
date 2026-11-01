import Cocoa
import Carbon

final class TextInjector {
    private struct PendingInjection {
        let text: String
        let onSubmission: ((TextDeliverySubmission) -> Void)?
        let completion: ((TextDeliveryResult) -> Void)?
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
    private let platform: TextInjectionPlatform
    private let sleep: (Double) async -> Void
    private let pasteboardService: PasteboardServicing

    init(pasteboardService: PasteboardServicing = SystemPasteboardService(),
         platform: TextInjectionPlatform = SystemTextInjectionPlatform(),
         sleep: @escaping (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.pasteboardService = pasteboardService
        self.platform = platform
        self.sleep = sleep
    }

    func inject(text: String, onSubmission: ((TextDeliverySubmission) -> Void)? = nil, completion: ((TextDeliveryResult) -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [self] in
                inject(text: text, onSubmission: onSubmission, completion: completion)
            }
            return
        }

        pendingInjections.append(PendingInjection(text: text, onSubmission: onSubmission, completion: completion))
        processNextInjection()
    }

    private func processNextInjection() {
        guard !lifecycle.isActive, !pendingInjections.isEmpty else { return }

        let next = pendingInjections.removeFirst()
        guard !next.text.isEmpty else {
            next.onSubmission?(.notSubmitted)
            next.completion?(.init(submission: .notSubmitted, cleanup: .notNeeded))
            processNextInjection()
            return
        }

        let injectionID = UUID()
        lifecycle.start(id: injectionID)
        let text = next.text
        var didReportSubmission = false
        let reportSubmission: (TextDeliverySubmission) -> Void = { submission in
            guard !didReportSubmission else { return }
            didReportSubmission = true
            next.onSubmission?(submission)
        }
        let completion: (TextDeliveryResult) -> Void = { result in
            reportSubmission(result.submission)
            next.completion?(result)
        }

        // 主任务：跑完整粘贴流程，结束后在主线程上回收状态并推进队列。
        // (Main task: run the full paste pipeline, then reconcile state on main thread.)
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.performInject(text: text, injectionID: injectionID, onSubmission: reportSubmission)
            self.finishInjection(injectionID: injectionID, result: result, completion: completion)
        }

        // Watchdog 只取消尚未改写剪贴板的任务；提交后必须等待恢复完成，避免新旧注入交叉。
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.injectionWatchdogTimeout * 1_000_000_000))
            self?.handleWatchdog(injectionID: injectionID, textLength: text.count, completion: completion)
        }
    }

    @MainActor
    private func finishInjection(injectionID: UUID, result: TextDeliveryResult, completion: ((TextDeliveryResult) -> Void)?) {
        guard lifecycle.finish(id: injectionID) else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        activeTask = nil
        completion?(result)
        processNextInjection()
    }

    @MainActor
    private func handleWatchdog(injectionID: UUID, textLength: Int, completion: ((TextDeliveryResult) -> Void)?) {
        switch lifecycle.handleTimeout(id: injectionID) {
        case .cancel:
            DebugLog.error("[TextInjector] Injection timed out before clipboard commit after \(Self.injectionWatchdogTimeout)s, textLength=\(textLength)")
            activeTask?.cancel()
            activeTask = nil
            watchdogTask = nil
            completion?(.init(submission: .notSubmitted, cleanup: .notNeeded))
            processNextInjection()
        case .waitForCleanup:
            DebugLog.error("[TextInjector] Injection exceeded \(Self.injectionWatchdogTimeout)s after clipboard commit; waiting for cleanup, textLength=\(textLength)")
            watchdogTask = nil
        case .stale:
            break
        }
    }

    @MainActor
    private func performInject(text: String, injectionID: UUID, onSubmission: (TextDeliverySubmission) -> Void) async -> TextDeliveryResult {
        let unsubmitted = TextDeliveryResult(submission: .notSubmitted, cleanup: .notNeeded)
        // 在主线程上读取前台应用的 bundleID，命中内置兼容性清单时改用更长的粘贴延迟，避免远程桌面/虚拟机/串流类应用丢字符。
        // (Resolve frontmost app on main thread to pick per-app paste delay override for remote desktop / VM / streaming clients.)
        let target = platform.target()
        let targetPID = target.processID
        let compatProfile = target.profile
        let postPaste = await platform.preparePaste(for: target)
        guard !Task.isCancelled,
              lifecycle.transition(id: injectionID, from: .preparing, to: .snapshotting) else {
            return unsubmitted
        }

        let captureResult = await pasteboardService.capture(timeout: Self.pasteboardSnapshotTimeout)
        guard !Task.isCancelled, lifecycle.isCurrent(injectionID) else { return unsubmitted }
        guard case .captured(let snapshot) = captureResult else {
            logCaptureFailure(captureResult)
            return unsubmitted
        }

        var finalText = text
        if CursorPunctuationProbe.needsLookup(text) {
            // 快照完成后才查询光标，缩短结果到写入的间隔；局部 AX 失败时直接保留原文。
            finalText = await platform.textForInsertion(text, targetPID: targetPID)
        }
        guard !Task.isCancelled, lifecycle.isCurrent(injectionID) else { return unsubmitted }
        guard platform.frontmostProcessID() == targetPID else {
            DebugLog.error("[TextInjector] Frontmost app changed before clipboard write; cancelling injection id=\(injectionID.uuidString)")
            return unsubmitted
        }
        DebugLog.debug("[TextInjector] Clipboard captured id=\(injectionID.uuidString) changeCount=\(snapshot.changeCount)")

        // 从这里开始剪贴板可能被改写，不能再由 watchdog 直接推进下一项。
        guard lifecycle.transition(id: injectionID, from: .snapshotting, to: .committing) else { return unsubmitted }
        let writeResult = await pasteboardService.write(
            text: finalText,
            replacing: snapshot
        )
        guard lifecycle.isCurrent(injectionID) else { return unsubmitted }
        guard case .written(let injectedChangeCount) = writeResult else {
            DebugLog.error("[TextInjector] Clipboard changed or could not be written before paste")
            if case .failedAfterRollback(let rollback) = writeResult {
                return .init(submission: .notSubmitted, cleanup: rollback.deliveryCleanup)
            }
            return unsubmitted
        }
        DebugLog.debug("[TextInjector] Clipboard committed id=\(injectionID.uuidString) changeCount=\(injectedChangeCount)")

        // 检查当前输入源是否为 CJK，如需要则切换到 ASCII（Check current input source, switch to ASCII if needed）
        let inputSource = platform.prepareInputSource()
        let needsSwitch = inputSource.needsSwitch

        // 任意提前返回也恢复输入源；正常路径仍在读取窗口之前恢复。
        var inputSourceRestored = false
        defer {
            if needsSwitch && !inputSourceRestored { inputSource.restore() }
        }
        var submission = TextDeliverySubmission.notSubmitted

        // 短暂等待输入源切换生效（Wait briefly for input source switch to take effect）
        await sleep(needsSwitch ? 0.05 : 0.02)
        guard lifecycle.isCurrent(injectionID) else { return unsubmitted }
        guard platform.frontmostProcessID() == targetPID else {
            DebugLog.error("[TextInjector] Frontmost app changed before paste; restoring without posting event id=\(injectionID.uuidString)")
            inputSource.restore()
            inputSourceRestored = true
            let restoreResult = await pasteboardService.restore(
                snapshot,
                expectedChangeCount: injectedChangeCount
            )
            if case .failed = restoreResult {
                DebugLog.error("[TextInjector] Failed to restore clipboard after target change id=\(injectionID.uuidString)")
            }
            return .init(submission: .notSubmitted, cleanup: restoreResult.deliveryCleanup)
        }
        submission = await postPaste()
        onSubmission(submission)

        // 粘贴延迟：给目标 App（含 Electron 等慢应用）足够时间完成粘贴；debug build 可在菜单调节。
        // 远程桌面 / 虚拟机 / 串流类应用命中兼容性清单时使用更长的延迟，避免键盘转发掉字符。
        // (Paste delay: enough time for target apps incl. Electron; tunable via debug menu.
        //  Remote-desktop / VM / streaming clients matched by compatibility registry use a longer override to avoid dropped characters.)
        let pasteDelay = max(AppSettings.pasteDelay, compatProfile?.pasteDelay ?? 0)
        await sleep(pasteDelay)
        guard lifecycle.isCurrent(injectionID) else { return unsubmitted }

        if needsSwitch {
            inputSource.restore()
            inputSourceRestored = true
        }

        // 再留出一段读取窗口后恢复剪贴板。单等一帧在低配机器上不够：Cmd+V 事件可能
        // 尚未被目标应用处理，过早恢复会把旧剪贴板内容粘进去。
        // (Allow a real read window before restoring; one run-loop frame is insufficient on slow machines.)
        let readGrace = max(Self.postPasteReadGrace, (compatProfile?.pasteDelay ?? 0) * 1.5)
        await sleep(readGrace)
        guard lifecycle.transition(id: injectionID, from: .committing, to: .restoring) else { return unsubmitted }
        let restoreResult = await pasteboardService.restore(
            snapshot,
            expectedChangeCount: injectedChangeCount
        )
        if case .failed = restoreResult {
            DebugLog.error("[TextInjector] Failed to restore clipboard contents")
        } else {
            DebugLog.debug("[TextInjector] Clipboard restored id=\(injectionID.uuidString) result=\(String(describing: restoreResult))")
        }
        return .init(submission: submission, cleanup: restoreResult.deliveryCleanup)
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
}

private extension PasteboardRestoreResult {
    var deliveryCleanup: TextDeliveryCleanup {
        switch self {
        case .restored, .skippedChanged: return .completed
        case .failed: return .failed
        }
    }
}
