import Foundation

enum PrivacyPolicyURLProvider {
    static func currentURL(preferredLanguages: [String] = Locale.preferredLanguages) -> URL {
        let lang = preferredLanguages.first ?? "en"
        let file: String
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
            file = "PRIVACY-zh-Hant.md"
        } else if lang.hasPrefix("zh") {
            file = "PRIVACY-zh-Hans.md"
        } else if lang.hasPrefix("ja") {
            file = "PRIVACY-ja.md"
        } else if lang.hasPrefix("ko") {
            file = "PRIVACY-ko.md"
        } else if lang.hasPrefix("es") {
            file = "PRIVACY-es.md"
        } else if lang.hasPrefix("fr") {
            file = "PRIVACY-fr.md"
        } else if lang.hasPrefix("de") {
            file = "PRIVACY-de.md"
        } else {
            file = "PRIVACY-en.md"
        }
        return URL(string: "https://github.com/BlackSquarre/AtomVoice/blob/main/README/privacy/\(file)")!
    }
}
