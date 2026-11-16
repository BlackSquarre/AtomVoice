import Foundation

/// 页面的一次资源快照；只检查传入的预设，不承担全局缓存或模型有效性保证。
enum SherpaModelInventory {
    struct Entry {
        let preset: SherpaModelPreset
        let isDownloaded: Bool
    }

    static func scan(
        presets: [SherpaModelPreset],
        paths: SherpaResourcePaths = .current,
        inspect: (URL) -> Bool = { ModelManifest.inspect(in: $0) != nil }
    ) -> [Entry] {
        presets.map { Entry(preset: $0, isDownloaded: inspect(paths.model($0))) }
    }
}
