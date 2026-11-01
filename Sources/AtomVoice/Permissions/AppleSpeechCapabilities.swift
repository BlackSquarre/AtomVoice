import Speech

/// 本机识别能力与用户的 Speech 授权是两个事实，不能互相替代。
enum AppleSpeechCapabilities {
    static func supportsOnDeviceRecognition(for languageCode: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: languageCode))?.supportsOnDeviceRecognition == true
    }
}
