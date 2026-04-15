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

        fnKeyMonitor = FnKeyMonitor(
            onFnDown: { [weak self] in self?.startRecording() },
            onFnUp: { [weak self] in self?.stopRecording() }
        )
        fnKeyMonitor.onTapDisabled = { [weak self] in
            self?.menuBarController.showAccessibilityWarning()
        }
        fnKeyMonitor.start()
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "需要麦克风权限"
                    alert.informativeText = "请在系统设置 > 隐私与安全性 > 麦克风中授权本应用。"
                    alert.runModal()
                }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "需要语音识别权限"
                    alert.informativeText = "请在系统设置 > 隐私与安全性 > 语音识别中授权本应用。"
                    alert.runModal()
                }
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        DispatchQueue.main.async { [self] in
            capsuleWindow.show()

            let request = speechRecognizer.start { [weak self] text, isFinal in
                DispatchQueue.main.async {
                    self?.capsuleWindow.updateText(text)
                }
            }

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
                llmRefiner.refine(text: processedText) { [weak self] refined in
                    DispatchQueue.main.async {
                        let finalText = refined ?? processedText
                        self?.capsuleWindow.updateText(finalText)
                        let delay = UserDefaults.standard.double(forKey: "llmResultDelay")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self?.capsuleWindow.dismiss {
                                self?.textInjector.inject(text: finalText)
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
}
