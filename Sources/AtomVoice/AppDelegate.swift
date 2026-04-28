import Cocoa
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var fnKeyMonitor: FnKeyMonitor!
    private var audioEngine: AudioEngineController!
    private var speechRecognizer: SpeechRecognizerController!
    private var capsuleWindow: CapsuleWindowController!
    private var textInjector: TextInjector!
    private var llmRefiner: LLMRefiner!
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "selectedLanguage": "zh-CN",
            "llmEnabled": false,
            "llmAPIBaseURL": "https://api.openai.com/v1",
            "llmModel": "gpt-4o-mini",
            "autoPunctuationEnabled": true,
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

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard isRecording else { return }
        // 静音模式（单击说话）下，切换窗口是正常流程，不取消录音
        let silenceMode = UserDefaults.standard.bool(forKey: "silenceAutoStopEnabled")
        if silenceMode { return }
        // 长按模式下切换了前台应用，取消本次录音
        cancelRecording()
    }

    // MARK: - Window activation helpers

    /// 在 LSUIElement=true (accessory) 模式下，普通 activate() 不会夺焦。
    /// 显示任何普通窗口前调用此函数切换策略并强制置前。
    static func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// 窗口关闭时调用：若已无其他普通窗口可见，恢复 accessory 策略。
    static func resetActivationIfNeeded(closing: NSWindow) {
        let hasOther = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !hasOther { NSApp.setActivationPolicy(.accessory) }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.mic.title")
                    alert.informativeText = loc("permission.mic.message")
                    alert.runModal()
                }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.speech.title")
                    alert.informativeText = loc("permission.speech.message")
                    alert.runModal()
                }
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        
        // 取消正在进行的 LLM 处理（如果有）
        llmRefiner.cancel()
        
        isRecording = true
        fnKeyMonitor.isRecording = true

        DispatchQueue.main.async { [self] in
            capsuleWindow.show()

            let request = speechRecognizer.start(
                onResult: { [weak self] text, isFinal in
                    DispatchQueue.main.async {
                        self?.capsuleWindow.updateText(text)
                    }
                },
                onRequestSwitch: { [weak self] newRequest in
                    self?.audioEngine.switchRequest(newRequest)
                }
            )

            audioEngine.start(
                bandsHandler: { [weak self] bands in
                    DispatchQueue.main.async {
                        self?.capsuleWindow.updateBands(bands)
                    }
                },
                recognitionRequest: request
            )
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            let rawText = speechRecognizer.stop()
            audioEngine.stop()

            if rawText.isEmpty {
                capsuleWindow.dismiss()
                return
            }

            // 本地自动标点
            var processedText = rawText
            if UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") {
                let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
                processedText = PunctuationProcessor.process(rawText, language: lang)
                capsuleWindow.updateText(processedText)
            }

            let llmEnabled = UserDefaults.standard.bool(forKey: "llmEnabled")
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

    /// ESC 取消录音：停止一切，不注入文字
    private func cancelRecording() {
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            llmRefiner.cancel()
            _ = speechRecognizer.stop()
            audioEngine.stop()
            capsuleWindow.dismiss()
        }
    }

    /// Space/Backspace 立即上屏：停止录音，跳过 LLM，直接注入
    private func stopRecordingImmediate() {
        guard isRecording else { return }
        isRecording = false
        fnKeyMonitor.isRecording = false

        DispatchQueue.main.async { [self] in
            let rawText = speechRecognizer.stop()
            audioEngine.stop()

            if rawText.isEmpty {
                capsuleWindow.dismiss()
                return
            }

            // 本地自动标点（保留），但跳过 LLM
            var processedText = rawText
            if UserDefaults.standard.bool(forKey: "autoPunctuationEnabled") {
                let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "zh-CN"
                processedText = PunctuationProcessor.process(rawText, language: lang)
            }

            capsuleWindow.dismiss { [self] in
                textInjector.inject(text: processedText)
            }
        }
    }
}
