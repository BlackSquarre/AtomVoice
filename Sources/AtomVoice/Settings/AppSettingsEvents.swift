import Foundation

/// 设置层向外发布的领域事件；把原本散落在多个文件里的 Notification.Name 字符串和
/// userInfo[String] 收编到一个 typed enum，发布方和订阅方共享同一份契约。
/// (Domain events published by the settings layer; replaces scattered Notification.Name
/// literals and userInfo[String] lookups with a typed enum shared by publisher and subscriber.)
enum AppSettingsEvent: Equatable {
    /// 识别引擎、Sherpa preset/provider/语言等触发模型重建的设置发生变更；附带的 key 是 AppSettings.Keys 之一。
    /// (Recognition engine / Sherpa preset / provider / language changed — `key` is one of AppSettings.Keys.)
    case recognitionEngineSettingsChanged(key: String)
    /// LLM 优化开关切换。
    /// (LLM refinement toggle flipped.)
    case llmEnabledDidChange
}

enum AppSettingsEventBus {
    static let recognitionEngineNotification = Notification.Name("AppSettings.recognitionEngineSettingsDidChange")
    static let llmEnabledNotification = Notification.Name("LLMSettings.enabledDidChange")
    private static let keyUserInfoField = "key"

    /// 把 typed event 落到 NotificationCenter；订阅方可通过 `decode` 还原。
    /// (Publish a typed event onto NotificationCenter; subscribers can decode it back.)
    static func publish(
        _ event: AppSettingsEvent,
        on center: NotificationCenter = .default,
        from object: Any?
    ) {
        switch event {
        case .recognitionEngineSettingsChanged(let key):
            center.post(
                name: recognitionEngineNotification,
                object: object,
                userInfo: [keyUserInfoField: key]
            )
        case .llmEnabledDidChange:
            center.post(name: llmEnabledNotification, object: object)
        }
    }

    /// 从 Notification 还原 typed event；name 不匹配时返回 nil。
    /// (Decode a Notification back to a typed event; returns nil for unrelated notifications.)
    static func decode(_ notification: Notification) -> AppSettingsEvent? {
        switch notification.name {
        case recognitionEngineNotification:
            let key = (notification.userInfo?[keyUserInfoField] as? String) ?? ""
            return .recognitionEngineSettingsChanged(key: key)
        case llmEnabledNotification:
            return .llmEnabledDidChange
        default:
            return nil
        }
    }
}
