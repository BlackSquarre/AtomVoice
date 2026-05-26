import Foundation

/// 应用 bundle 元数据的集中读取入口，避免 `Bundle.main.infoDictionary?[...]` 在多处复述。
/// (Single entry for app bundle metadata; replaces scattered `Bundle.main.infoDictionary?[...]` reads.)
enum AppBundleInfo {
    /// CFBundleShortVersionString，用户可见的版本号；缺失时回退 "0"。
    /// (CFBundleShortVersionString, the user-facing version string; falls back to "0" if missing.)
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// CFBundleVersion，构建号；缺失时回退 "1"。
    /// (CFBundleVersion, the build number; falls back to "1" if missing.)
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
