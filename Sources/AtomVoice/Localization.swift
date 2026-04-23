import Foundation

/// 全局本地化快捷函数
func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""), arguments: args)
}
