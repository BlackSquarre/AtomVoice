import Cocoa
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var fnKeyMonitor: FnKeyMonitor!
    private var audioEngine: AudioEngineController!
    private var speechRecognizer: SpeechRecognizerController!
    private var sherpaRecognizer: SherpaOnnxRecognizerController!
    private var capsuleWindow: CapsuleWindowController!
    private var textInjector: TextInjector!
    private var llmRefiner: LLMRefiner!
    private var isRecording = false
    private var currentRecordingEngine = "apple"
    private var liveInsertionActive = false
    private var liveInsertionCommittedText = ""
    private var liveInsertionLatestText = ""
    private var liveInsertionPasteInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherRunningInstances()

        UserDefaults.standard.register(defaults: [
            "selectedLanguage": "zh-CN",
            "recognitionEngine": "apple",
            "appleLiveInsertionEnabled": false,
            "llmEnabled": false,
            "llmAPIBaseURL": "https://api.openai.com/v1",
            "llmModel": "gpt-4o-mini",
            "autoPunctuationEnabled": true,
            "appleOnDeviceRecognitionEnabled": false,
            "llmResultDelay": 0.3,
            "animationStyle": "dynamicIsland",
            "animationSpeed": "medium",
            "silenceAutoStopEnabled": false,
            "silenceDuration": 2.0,
            "silenceThreshold": -40.0,
            "triggerKeyCode": 63,
        ])

        requestPermissions()

        llmRefiner = LLMRefiner()
        textInjector = TextInjector()
        capsuleWindow = CapsuleWindowController()
        audioEngine = AudioEngineController()
        speechRecognizer = SpeechRecognizerController()
        sherpaRecognizer = SherpaOnnxRecognizerController()

        menuBarController = MenuBarController(
            onLanguageChanged: { [weak self] in
                self?.speechRecognizer.updateLanguage()
            },
            llmRefiner: llmRefiner
        )

        audioEngine.onSilenceTimeout = { [weak self] in self?.stopRecording() }

        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in
                guard let self else { return }
                let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
                if silenceMode {
                    // 切换模式：按一次开始，再按一次手动停止
                    if self.isRecording {
                        self.stopRecording()
                    } else {
                        self.startRecording()
                    }
                } else {
                    self.startRecording()
                }
            },
            onFnUp: { [weak self] in
                guard let self else { return }
                let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
                // 静音模式下松开 Fn 不停止录音
                if !silenceMode {
                    self.stopRecording()
                }
            }
        )
        fnKeyMonitor.triggerKeyCode = UInt16(UserDefaults.standard.integer(forKey: "triggerKeyCode"))
        fnKeyMonitor.onTapDisabled = { [weak self] in
            self?.menuBarController.showAccessibilityWarning()
        }
        menuBarController.onTriggerKeyChanged = { [weak self] keyCode in
            self?.fnKeyMonitor.triggerKeyCode = keyCode
        }
        // ESC 取消录音（不上屏）
        fnKeyMonitor.onEscPressed = { [weak self] in self?.cancelRecording() }
        // Space/Backspace 立即上屏（跳过 LLM）
        fnKeyMonitor.onImmediateStop = { [weak self] in self?.stopRecordingImmediate() }
        fnKeyMonitor.start()

        // 启动 5 秒后静默检查更新（不阻塞启动流程）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkForUpdates(silent: true)
        }

        // 监听前台应用切换：录音期间切换程序则取消录音
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func terminateOtherRunningInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }
        guard !otherApps.isEmpty else { return }

        // 菜单栏应用不应该多开；新实例启动时清理旧实例，避免出现多个状态栏菜单。
        otherApps.forEach { app in
            print("[AppDelegate] 正在退出旧实例 pid=\(app.processIdentifier)")
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            otherApps.filter { !$0.isTerminated }.forEach { app in
                print("[AppDelegate] 旧实例未正常退出，强制结束 pid=\(app.processIdentifier)")
                app.forceTerminate()
            }
        }
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard isRecording else { return }
        // 静音模式（单击说话）下，切换窗口是正常流程，不取消录音
        let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        if silenceMode { return }
        // 长按模式下切换了前台应用，取消本次录音
        cancelRecording()
    }

    // MARK: - Window activation helpers

    /// 在 LSUIElement=true 的菜单栏应用里，窗口/弹窗要先切到可激活状态，
    /// 再显式激活当前 app 并把目标窗口提到最前。
    static func bringToFront(_ window: NSWindow) {
        activateForForegroundInteraction()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // 菜单项 action 执行时菜单还在收起过程中，下一轮 runloop 再抢一次焦点更稳定。
        DispatchQueue.main.async {
            activateForForegroundInteraction()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    @discardableResult
    static func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        activateForForegroundInteraction()
        alert.window.level = .modalPanel
        let response = alert.runModal()
        resetActivationIfNeeded()
        return response
    }

    /// 窗口关闭时调用：若已无其他普通窗口可见，恢复 accessory 策略。
    static func resetActivationIfNeeded(closing: NSWindow? = nil) {
        let hasOther = NSApp.windows.contains { window in
            if let closing, window === closing { return false }
            return window.isVisible && window.styleMask.contains(.titled)
        }
        if !hasOther { NSApp.setActivationPolicy(.accessory) }
    }

    private static func activateForForegroundInteraction() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let currentApp = NSRunningApplication.current
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp.processIdentifier != currentApp.processIdentifier {
            currentApp.activate(from: frontmostApp, options: [.activateAllWindows])
        } else {
            currentApp.activate(options: [.activateAllWindows])
        }
        NSApp.activate()
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.mic.title")
                    alert.informativeText = loc("permission.mic.message")
                    AppDelegate.runModalAlert(alert)
                }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.speech.title")
                    alert.informativeText = loc("permission.speech.message")
                    AppDelegate.runModalAlert(alert)
                }
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }

        guard !AudioEngineController.availableInputDevices().isEmpty else {
            DispatchQueue.main.async { [self] in
                capsuleWindow.show()
                capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
            }
            return
        }
        
        // 取消正在进行的 LLM 处理（如果有）
        llmRefiner.cancel()
        
        isRecording = true
        fnKeyMonitor.isRecording = true
        currentRecordingEngine = UserDefaults.standard.string(forKey: "recognitionEngine") ?? "apple"
        liveInsertionActive = currentRecordingEngine == "apple" &&
            UserDefaults.standard.bool(forKey: "appleLiveInsertionEnabled") &&
            !UserDefaults.standard.bool(forKey: "llmEnabled")
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false

        DispatchQueue.main.async { [self] in
            capsuleWindow.show()

            if currentRecordingEngine == "sherpaOnnx" {
                if let error = sherpaRecognizer.start(onResult: { [weak self] text, _ in
                    DispatchQueue.main.async {
                        self?.capsuleWindow.updateText(text)
                    }
                }) {
                    isRecording = false
                    fnKeyMonitor.isRecording = false
                    capsuleWindow.showError(error, dismissAfter: 6)
                    return
                }

                if !audioEngine.start(
                    bandsHandler: { [weak self] bands in
                        DispatchQueue.main.async {
                            self?.capsuleWindow.updateBands(bands)
                        }
                    },
                    recognitionRequest: nil,
                    audioBufferHandler: { [weak self] buffer, _ in
                        self?.sherpaRecognizer.accept(buffer: buffer)
                    }
                ) {
                    _ = sherpaRecognizer.stop()
                    handleAudioStartFailure()
                }
            } else {
                let request = speechRecognizer.start(
                    onResult: { [weak self] text, isFinal in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.capsuleWindow.updateText(text)
                            self.commitAppleLiveSegmentIfNeeded(from: text, isFinal: isFinal)
                        }
                    },
                    onRequestSwitch: { [weak self] newRequest in
                        self?.audioEngine.switchRequest(newRequest)
                    }
                )

                if !audioEngine.start(
                    bandsHandler: { [weak self] bands in
                        DispatchQueue.main.async {
                            self?.capsuleWindow.updateBands(bands)
                        }
                    },
                    recognitionRequest: request
                ) {
                    _ = speechRecognizer.stop()
                    handleAudioStartFailure()
                }
            }
        }
    }

    private func handleAudioStartFailure() {
        isRecording = false
        fnKeyMonitor.isRecording = false
        liveInsertionActive = false
        liveInsertionCommittedText = ""
        liveInsertionLatestText = ""
        liveInsertionPasteInFlight = false
        capsuleWindow.showError(loc("error.noInputDevice"), dismissAfter: 5)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            let recognizedText = currentRecordingEngine == "sherpaOnnx" ? sherpaRecognizer.stop() : speechRecognizer.stop()
            audioEngine.stop()
            let rawText = remainingTextAfterLiveInsertion(recognizedText)

            if rawText.isEmpty {
                capsuleWindow.dismiss()
                return
            }

            let processedText = applyAutoPunctuation(to: rawText)
            if processedText != rawText {
                capsuleWindow.updateText(processedText)
            }

            let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled") && liveInsertionCommittedText.isEmpty
            let apiKey = UserDefaults.standard.string(forKey: "llmAPIKey") ?? ""

            if llmEnabled && !apiKey.isEmpty {
                capsuleWindow.showRefining()
                llmRefiner.refine(text: processedText, onProgress: { [weak self] partial in
                    self?.capsuleWindow.updateText(partial)
                }) { [weak self] refined, errorMsg in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let errorMsg {
                            // 立即注入文字，同时胶囊显示错误 3 秒
                            self.textInjector.inject(text: processedText)
                            self.capsuleWindow.showError(errorMsg)
                            return
                        }
                        let finalText = refined ?? processedText
                        self.capsuleWindow.updateText(finalText)
                        let delay = UserDefaults.standard.double(forKey: "llmResultDelay")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.capsuleWindow.dismiss {
                                self.textInjector.inject(text: finalText)
                            }
                        }
                    }
                }
            } else {
                capsuleWindow.dismiss { [self] in
                    textInjector.inject(text: processedText)
                }
            }
        }
    }

    private func commitAppleLiveSegmentIfNeeded(from text: String, isFinal: Bool) {
        guard liveInsertionActive, isRecording, currentRecordingEngine == "apple" else { return }
        liveInsertionLatestText = text
        guard !liveInsertionPasteInFlight else { return }
        guard text.hasPrefix(liveInsertionCommittedText) else { return }

        let uncommitted = String(text.dropFirst(liveInsertionCommittedText.count))
        guard let endIndex = committableLiveSegmentEnd(in: uncommitted, isFinal: isFinal) else { return }

        let segment = String(uncommitted[..<endIndex])
        guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        liveInsertionCommittedText += segment
        liveInsertionPasteInFlight = true
        textInjector.inject(text: segment) { [weak self] in
            guard let self else { return }
            self.liveInsertionPasteInFlight = false
            if self.isRecording {
                self.commitAppleLiveSegmentIfNeeded(from: self.liveInsertionLatestText, isFinal: false)
            }
        }
    }

    private func committableLiveSegmentEnd(in text: String, isFinal: Bool) -> String.Index? {
        var sentenceEnds: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if PunctuationProcessor.isSentenceEndingPunctuation(text[index]) {
                var end = next
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                sentenceEnds.append(end)
            }
            index = next
        }

        for end in sentenceEnds.reversed() {
            let candidate = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 3, isFinal || trailing.count >= 3 {
                return end
            }
        }

        return nil
    }

    private func remainingTextAfterLiveInsertion(_ text: String) -> String {
        guard liveInsertionActive, !liveInsertionCommittedText.isEmpty else { return text }

        if text.hasPrefix(liveInsertionCommittedText) {
            return String(text.dropFirst(liveInsertionCommittedText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let committed = liveInsertionCommittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty, text.hasPrefix(committed) {
            return String(text.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commonPrefixEnd = commonPrefixEndIndex(in: text, with: liveInsertionCommittedText)
        let commonPrefixLength = text.distance(from: text.startIndex, to: commonPrefixEnd)
        if commonPrefixLength > 0 {
            print("[LiveInsertion] 最终文本与已上屏前缀不完全一致，从共同前缀后继续注入")
            return String(text[commonPrefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("[LiveInsertion] 最终文本与已上屏前缀不一致，注入完整最终文本以避免丢字")
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

    private func applyAutoPunctuation(to rawText: String) -> String {
        guard UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") else { return rawText }

        if currentRecordingEngine == "sherpaOnnx",
           let punctuated = sherpaRecognizer.punctuate(rawText) {
            return punctuated
        }

        let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
        return PunctuationProcessor.process(rawText, language: lang)
    }

    /// ESC 取消录音：停止一切，不注入文字
    private func cancelRecording() {
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            llmRefiner.cancel()
            if currentRecordingEngine == "sherpaOnnx" {
                _ = sherpaRecognizer.stop()
            } else {
                _ = speechRecognizer.stop()
            }
            audioEngine.stop()
            liveInsertionActive = false
            liveInsertionCommittedText = ""
            liveInsertionLatestText = ""
            liveInsertionPasteInFlight = false
            capsuleWindow.dismiss()
        }
    }

    /// Space/Backspace 立即上屏：停止录音，跳过 LLM，直接注入
    private func stopRecordingImmediate() {
        guard isRecording else { return }
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            let recognizedText = currentRecordingEngine == "sherpaOnnx" ? sherpaRecognizer.stop() : speechRecognizer.stop()
            audioEngine.stop()
            let rawText = remainingTextAfterLiveInsertion(recognizedText)

            if rawText.isEmpty {
                capsuleWindow.dismiss()
                return
            }

            // 本地自动标点（保留），但跳过 LLM
            let processedText = applyAutoPunctuation(to: rawText)

            capsuleWindow.dismiss { [self] in
                textInjector.inject(text: processedText)
            }
        }
    }
}
