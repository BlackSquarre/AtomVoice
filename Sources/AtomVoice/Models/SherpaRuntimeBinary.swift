import Foundation

/// 只读 Mach-O 头，安装前确认当前架构和最低系统；不会加载动态库或模型。
enum SherpaRuntimeBinary {
    #if arch(arm64)
    static let currentCPU: UInt32 = 0x0100000c
    #else
    static let currentCPU: UInt32 = 0x01000007
    #endif

    static func supports(_ url: URL, on os: OperatingSystemVersion) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let minimum = minimumVersion(in: data, cpu: currentCPU) else { return false }
        let current = [os.majorVersion, os.minorVersion, os.patchVersion]
        return !current.lexicographicallyPrecedes([minimum.majorVersion, minimum.minorVersion, minimum.patchVersion])
    }

    static func minimumVersion(in data: Data, cpu: UInt32) -> OperatingSystemVersion? {
        func u32(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = data[offset..<offset + 4]
            return (big ? Array(bytes) : Array(bytes.reversed())).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var slices: [(Int, Int)] = []
        if u32(0, big: true) == 0xcafebabe {
            guard let count = u32(4, big: true), count <= 32 else { return nil }
            for index in 0..<Int(count) {
                let p = 8 + 20 * index
                guard let offset = u32(p + 8, big: true), let size = u32(p + 12, big: true) else { return nil }
                slices.append((Int(offset), Int(size)))
            }
        } else { slices = [(0, data.count)] }
        for (offset, size) in slices {
            guard size >= 32, offset >= 0, offset <= data.count, size <= data.count - offset,
                  u32(offset) == 0xfeedfacf, u32(offset + 4) == cpu,
                  let commands = u32(offset + 16), let commandBytes = u32(offset + 20),
                  Int(commandBytes) <= size - 32, commands <= commandBytes / 8 else { continue }
            let end = offset + 32 + Int(commandBytes)
            var p = offset + 32
            for _ in 0..<commands {
                guard p <= end - 8, let command = u32(p), let length = u32(p + 4),
                      length >= 8, Int(length) <= end - p else { return nil }
                let encoded: UInt32?
                if command == 0x32, length >= 24, u32(p + 8) == 1 { encoded = u32(p + 12) }
                else if command == 0x24, length >= 16 { encoded = u32(p + 8) }
                else { encoded = nil }
                if let encoded {
                    return .init(majorVersion: Int(encoded >> 16), minorVersion: Int((encoded >> 8) & 255), patchVersion: Int(encoded & 255))
                }
                p += Int(length)
            }
        }
        return nil
    }
}
