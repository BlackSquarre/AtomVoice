import Cocoa
import Speech

final class AppleSettingsTab: ASRSettingsTab {
    let identifier = "apple"
    let label = loc("asrSettings.tab.apple")

    private var appleEnableCheckbox: NSButton!
    private var appleStatusLabel: NSTextField!

    func makeView() -> NSView {
        let view = NSView()

        let descLabel = NSTextField(labelWithString: loc("asrSettings.apple.desc"))
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // 当前状态（Current status）
        let currentLang = AppSettings.selectedLanguage
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true

        appleStatusLabel = NSTextField(labelWithString: "")
        appleStatusLabel.font = .systemFont(ofSize: 13)
        appleStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateAppleStatus()

        // 启用复选框（Enable checkbox）
        let isEnabled = AppSettings.appleOnDeviceRecognitionEnabled
        appleEnableCheckbox = SettingsUI.makeCheckbox(title: loc("asrSettings.apple.enable"), tooltip: "")
        appleEnableCheckbox.state = isEnabled ? .on : .off
        appleEnableCheckbox.isEnabled = isSupported
        appleEnableCheckbox.translatesAutoresizingMaskIntoConstraints = false

        // 注意事项（Notes）
        let noteLabel = NSTextField(labelWithString: loc("asrSettings.apple.note"))
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 0
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        // 打开系统设置按钮（Open System Settings button）
        let openSettingsButton = SettingsUI.makeButton(loc("asrSettings.apple.openSettings"), target: self, action: #selector(openAppleSettings(_:)))
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(descLabel)
        view.addSubview(appleStatusLabel)
        view.addSubview(appleEnableCheckbox)
        view.addSubview(noteLabel)
        view.addSubview(openSettingsButton)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            appleStatusLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            appleStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            appleEnableCheckbox.topAnchor.constraint(equalTo: appleStatusLabel.bottomAnchor, constant: 12),
            appleEnableCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            noteLabel.topAnchor.constraint(equalTo: appleEnableCheckbox.bottomAnchor, constant: 16),
            noteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            openSettingsButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            openSettingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        return view
    }

    func refresh() {
        updateAppleStatus()
    }

    func save() -> ASRSettingsTabSaveOutcome {
        persistAppleSettings()
        return .saved
    }

    private func updateAppleStatus() {
        let currentLang = AppSettings.selectedLanguage
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true

        if isSupported {
            appleStatusLabel?.stringValue = loc("asrSettings.apple.status") + " ✓ " + loc("asrSettings.apple.modelDownloaded")
            appleStatusLabel?.textColor = .systemGreen
        } else {
            appleStatusLabel?.stringValue = loc("asrSettings.apple.status") + " " + loc("asrSettings.apple.modelNotDownloaded")
            appleStatusLabel?.textColor = .systemOrange
        }
    }

    private func persistAppleSettings() {
        let appleEnabled = appleEnableCheckbox.state == .on
        let currentLang = AppSettings.selectedLanguage
        let isSupported = SFSpeechRecognizer(locale: Locale(identifier: currentLang))?.supportsOnDeviceRecognition == true
        if appleEnabled && !isSupported {
            // 不支持时强制关闭（Force off when unsupported）
            AppSettings.appleOnDeviceRecognitionEnabled = false
        } else {
            AppSettings.appleOnDeviceRecognitionEnabled = appleEnabled
        }
    }

    @objc private func openAppleSettings(_ sender: NSButton) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }
}
