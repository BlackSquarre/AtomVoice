import Cocoa

/// 手动导入 Sherpa 模型包流程（Manual Sherpa model import flow）
/// 支持 .tar.bz2 / .tar.gz / .tgz / .zip / 已解压目录
/// (Supports .tar.bz2 / .tar.gz / .tgz / .zip archives, or already-extracted directory)
final class SherpaModelImportFlow {
    /// 完成回调（main thread）；nil 表示用户取消或失败
    /// (Completion callback on main thread; nil = cancelled or failed)
    typealias Completion = (SherpaImportedPresetRecord?) -> Void

    private weak var parentWindow: NSWindow?
    private let installer = SherpaModelImportInstaller()

    init(parentWindow: NSWindow?) {
        self.parentWindow = parentWindow
    }

    func run(completion: @escaping Completion) {
        let panel = NSOpenPanel()
        panel.title = loc("sherpa.import.pickerTitle")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []  // 用 fileExtensions 兼容更多压缩格式（use ext check for more formats）

        let runPick: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { completion(nil); return }
            guard response == .OK, let url = panel.url else { completion(nil); return }
            self.handlePicked(url: url, completion: completion)
        }

        if let parentWindow {
            panel.beginSheetModal(for: parentWindow, completionHandler: runPick)
        } else {
            runPick(panel.runModal())
        }
    }

    // MARK: - 处理选择（Handle picked URL）

    private func handlePicked(url: URL, completion: @escaping Completion) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            switch self.installer.prepare(url) {
            case .failure(let error):
                DispatchQueue.main.async { self.showError(error); completion(nil) }
            case .success(let prepared):
                DispatchQueue.main.async {
                    self.askLanguage(for: prepared.directory, sizeMB: prepared.sizeMB) { language in
                        guard let language else { completion(nil); return }
                        let record = SherpaImportedPresetRecord(
                            id: self.uniqueImportID(from: prepared.targetName), language: language,
                            extractedDirName: prepared.targetName, sizeMB: prepared.sizeMB, importedAt: Date())
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = self.installer.install(prepared, record: record)
                            DispatchQueue.main.async {
                                switch result {
                                case .success: completion(record)
                                case .failure(let error): self.showError(error); completion(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 收尾（Finalization）

    private func askLanguage(for modelDir: URL, sizeMB: Int, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.import.languageTitle")

        // 优先使用从目录名识别到的语言；识别不到则回退到用户当前的识别语言
        // (Prefer language inferred from directory name; fall back to current recognition language)
        let detectedLang = Self.detectLanguage(fromDirName: modelDir.lastPathComponent)
        let fallbackLang = AppSettings.sherpaRecognitionLanguage
        let presetLang = detectedLang ?? fallbackLang

        var info = loc("sherpa.import.languageMessage", modelDir.lastPathComponent, sizeMB)
        if let detected = detectedLang {
            info += "\n" + loc("sherpa.import.detected", AppSettings.displayName(forRecognitionLanguage: detected))
        }
        alert.informativeText = info

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24), pullsDown: false)
        for code in SherpaModelPreset.supportedRecognitionLanguages {
            let item = NSMenuItem(title: AppSettings.displayName(forRecognitionLanguage: code), action: nil, keyEquivalent: "")
            item.representedObject = code
            popup.menu?.addItem(item)
        }
        if let item = popup.menu?.items.first(where: { ($0.representedObject as? String) == presetLang }) {
            popup.select(item)
        }
        alert.accessoryView = popup

        alert.addButton(withTitle: loc("sherpa.import.confirm"))
        alert.addButton(withTitle: loc("common.cancel"))

        let response = AlertPresenter.shared.runModalAlert(alert)
        guard response == .alertFirstButtonReturn,
              let lang = popup.selectedItem?.representedObject as? String else {
            completion(nil)
            return
        }
        completion(lang)
    }

    private func uniqueImportID(from baseName: String) -> String {
        // 用目录名做 ID 的基础；与已有内置/导入 preset 撞名时加后缀
        // (Use directory name as ID base; suffix on collision)
        let existing = Set(SherpaModelPreset.allPresets.map { $0.id })
        if !existing.contains(baseName) { return baseName }
        for i in 2...99 {
            let candidate = "\(baseName)#\(i)"
            if !existing.contains(candidate) { return candidate }
        }
        return baseName + "#" + UUID().uuidString.prefix(8)
    }

    /// 从目录名推断模型语言（Infer model language from directory name）
    /// Sherpa 命名约定较稳定：含 "bilingual"、"-zh-"/"chinese"、"-en-"/"english"、"-ja-"/"japanese"、
    /// "korean"/"-ko-"、"-fr-"/"french"、"-de-"/"german"、"-es-"/"spanish"
    /// (Sherpa naming is fairly consistent across releases)
    static func detectLanguage(fromDirName name: String) -> String? {
        let lower = "-" + name.lowercased() + "-"
        if lower.contains("bilingual") { return "bilingual" }
        if lower.contains("-zh-tw-") || lower.contains("traditional") || lower.contains("cantonese") { return "zh-TW" }
        if lower.contains("-zh-") || lower.contains("chinese") || lower.contains("mandarin") { return "zh-CN" }
        if lower.contains("japanese") || lower.contains("-ja-") || lower.contains("-jp-") { return "ja-JP" }
        if lower.contains("korean") || lower.contains("-ko-") || lower.contains("-kr-") { return "ko-KR" }
        if lower.contains("french") || lower.contains("-fr-") { return "fr-FR" }
        if lower.contains("german") || lower.contains("-de-") { return "de-DE" }
        if lower.contains("spanish") || lower.contains("-es-") { return "es-ES" }
        if lower.contains("-en-") || lower.contains("english") { return "en-US" }
        return nil
    }

    private func showError(_ error: SherpaImportError) {
        let alert = NSAlert()
        alert.messageText = loc("sherpa.import.failedTitle")
        alert.informativeText = error.userMessage
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        alert.addButton(withTitle: loc("common.ok"))
        _ = AlertPresenter.shared.runModalAlert(alert)
    }
}
