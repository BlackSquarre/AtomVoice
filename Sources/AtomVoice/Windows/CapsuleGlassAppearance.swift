import Cocoa

/// 输入胶囊与设置预览共用系统材质规则，不管理窗口或输入生命周期。
enum CapsuleGlassAppearance {
    @available(macOS 26.0, *)
    static func configure(_ glass: NSGlassEffectView, cornerRadius: CGFloat = 21) {
        glass.cornerRadius = cornerRadius
        let usesSystemTransparency = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
        if usesSystemTransparency {
            // macOS 27 的 Liquid Glass 透明度由系统控制，不固定 tint 或 alpha。
            glass.style = .regular
            glass.tintColor = nil
            let selector = NSSelectorFromString("setEffectIsInteractive:")
            if glass.responds(to: selector) {
                glass.setValue(true, forKey: "effectIsInteractive")
            }
        } else {
            glass.style = .clear
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.065)
        }
    }
}
