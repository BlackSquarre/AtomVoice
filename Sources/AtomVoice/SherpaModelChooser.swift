import Cocoa

/// Sherpa 模型选择器窗口（Sherpa Model Chooser Window）
/// OOBE 完成前以及"切换到 Sherpa 引擎且当前模型未下载"的场景下使用
/// (Used during OOBE before finish and when switching to Sherpa with current model not downloaded)
final class SherpaModelChooserController: NSObject {
    /// 用户确认后回调；nil 表示取消（Called on confirm; nil = cancelled）
    var onComplete: ((language: String, modelID: String)?) -> Void = { _ in }

    private var window: NSWindow?
    private var languagePopup: NSPopUpButton!
    private var radioStack: NSStackView!
    private var radios: [NSButton] = []
    private var radioModelIDs: [NSButton: String] = [:]
    private var sizeNote: NSTextField!

    func runModal(over parentWindow: NSWindow?) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = loc("sherpa.chooser.title")
        w.isReleasedWhenClosed = false

        guard let cv = w.contentView else { return }
        let pad: CGFloat = 20

        let header = NSTextField(labelWithString: loc("sherpa.chooser.header"))
        header.font = .systemFont(ofSize: 13, weight: .medium)
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        let langLabel = NSTextField(labelWithString: loc("asrSettings.sherpa.recognitionLanguage"))
        langLabel.font = .systemFont(ofSize: 12)
        langLabel.translatesAutoresizingMaskIntoConstraints = false

        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let currentLang = SherpaModelPreset.recognitionLanguage
        for code in SherpaModelPreset.supportedRecognitionLanguages {
            let item = NSMenuItem(title: displayName(code), action: nil, keyEquivalent: "")
            item.representedObject = code
            languagePopup.menu?.addItem(item)
            if code == currentLang { languagePopup.select(item) }
        }

        let langRow = NSStackView(views: [langLabel, languagePopup])
        langRow.orientation = .horizontal
        langRow.spacing = 8
        langRow.alignment = .centerY
        langRow.translatesAutoresizingMaskIntoConstraints = false

        radioStack = NSStackView()
        radioStack.orientation = .vertical
        radioStack.alignment = .leading
        radioStack.spacing = 6
        radioStack.translatesAutoresizingMaskIntoConstraints = false

        sizeNote = NSTextField(labelWithString: "")
        sizeNote.font = .systemFont(ofSize: 11)
        sizeNote.textColor = .secondaryLabelColor
        sizeNote.lineBreakMode = .byWordWrapping
        sizeNote.maximumNumberOfLines = 0
        sizeNote.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: loc("common.cancel"), target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        let confirmBtn = NSButton(title: loc("sherpa.chooser.confirm"), target: self, action: #selector(confirmTapped))
        confirmBtn.bezelStyle = .rounded
        confirmBtn.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let btnRow = NSStackView(views: [spacer, cancelBtn, confirmBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(header)
        cv.addSubview(langRow)
        cv.addSubview(radioStack)
        cv.addSubview(sizeNote)
        cv.addSubview(btnRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: pad),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),

            langRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            langRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),

            radioStack.topAnchor.constraint(equalTo: langRow.bottomAnchor, constant: 14),
            radioStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad + 10),
            radioStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),

            sizeNote.topAnchor.constraint(equalTo: radioStack.bottomAnchor, constant: 12),
            sizeNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            sizeNote.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),

            btnRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: pad),
            btnRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -pad),
            btnRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -pad),
        ])

        rebuildModelList()
        updateSizeNote()

        window = w

        if let parentWindow {
            parentWindow.beginSheet(w) { _ in }
        } else {
            w.center()
            NSApp.runModal(for: w)
        }
    }

    // MARK: - Internal

    private func rebuildModelList() {
        radioStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        radios = []
        radioModelIDs = [:]

        let lang = (languagePopup.selectedItem?.representedObject as? String) ?? SherpaModelPreset.recognitionLanguage
        let presets = SherpaModelPreset.presets(forRecognitionLanguage: lang)
        let savedID = UserDefaults.standard.string(forKey: "sherpaModelPresetID")
        let presetIDs = Set(presets.map { $0.id })
        let activeID: String = (savedID.flatMap { presetIDs.contains($0) ? $0 : nil })
            ?? SherpaModelPreset.defaultModelID(forRecognitionLanguage: lang)

        for preset in presets {
            let mark = preset.isDownloaded ? "✓ " : ""
            let title = "\(mark)\(preset.id) (\(preset.sizeMB)MB)"
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioTapped(_:)))
            radio.state = preset.id == activeID ? .on : .off
            radioModelIDs[radio] = preset.id
            radios.append(radio)
            radioStack.addArrangedSubview(radio)
        }
    }

    private func updateSizeNote() {
        let selected = currentSelectedPreset()
        guard let preset = selected else {
            sizeNote.stringValue = ""
            return
        }
        if preset.isDownloaded {
            sizeNote.stringValue = loc("sherpa.chooser.note.downloaded", preset.id)
        } else {
            sizeNote.stringValue = loc("sherpa.chooser.note.toDownload", preset.sizeMB)
        }
    }

    private func currentSelectedPreset() -> SherpaModelPreset? {
        guard let radio = radios.first(where: { $0.state == .on }),
              let id = radioModelIDs[radio] else { return nil }
        return SherpaModelPreset.allPresets.first(where: { $0.id == id })
    }

    private func displayName(_ code: String) -> String {
        switch code {
        case "en-US": return "English"
        case "zh-CN": return "简体中文"
        case "zh-TW": return "繁體中文"
        case "ja-JP": return "日本語"
        case "ko-KR": return "한국어"
        case "es-ES": return "Español"
        case "fr-FR": return "Français"
        case "de-DE": return "Deutsch"
        case "bilingual": return loc("asrSettings.sherpa.lang.bilingual")
        default: return code
        }
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        rebuildModelList()
        updateSizeNote()
    }

    @objc private func radioTapped(_ sender: NSButton) {
        for r in radios { r.state = (r === sender) ? .on : .off }
        updateSizeNote()
    }

    @objc private func confirmTapped() {
        guard let lang = languagePopup.selectedItem?.representedObject as? String,
              let preset = currentSelectedPreset() else { return }
        UserDefaults.standard.set(lang, forKey: SherpaModelPreset.recognitionLanguageKey)
        UserDefaults.standard.set(preset.id, forKey: "sherpaModelPresetID")
        let result: (String, String)? = (lang, preset.id)
        endModal(result: result)
    }

    @objc private func cancelTapped() {
        endModal(result: nil)
    }

    private func endModal(result: (String, String)?) {
        guard let w = window else { return }
        if let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            NSApp.stopModal()
            w.close()
        }
        window = nil
        onComplete(result)
    }
}
