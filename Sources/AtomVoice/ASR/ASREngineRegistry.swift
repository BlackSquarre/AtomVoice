import Foundation

struct ASREngineDescriptor {
    let code: String
    let displayNameKey: String
    let iconName: String
    let isOffline: Bool
    let supportsStreaming: Bool
    let supportsPartialResults: Bool
    let supportsOnDevice: Bool
    let requiresCredential: Bool
}

extension ASREngineDescriptor {
    static let apple = ASREngineDescriptor(
        code: ASREngineRegistry.appleCode,
        displayNameKey: "menu.recognitionEngine.apple",
        iconName: "apple.logo",
        isOffline: false,
        supportsStreaming: true,
        supportsPartialResults: true,
        supportsOnDevice: true,
        requiresCredential: false
    )

    static let sherpaOnnx = ASREngineDescriptor(
        code: ASREngineRegistry.sherpaCode,
        displayNameKey: "menu.recognitionEngine.sherpaOnnx",
        iconName: "mountain.2.fill",
        isOffline: true,
        supportsStreaming: true,
        supportsPartialResults: true,
        supportsOnDevice: true,
        requiresCredential: false
    )

    static let volcengine = ASREngineDescriptor(
        code: VolcengineASRSettings.engineCode,
        displayNameKey: "menu.recognitionEngine.doubao",
        iconName: "cloud",
        isOffline: false,
        supportsStreaming: true,
        supportsPartialResults: true,
        supportsOnDevice: false,
        requiresCredential: true
    )
}

final class ASREngineRegistry {
    static let appleCode = "apple"
    static let sherpaCode = "sherpaOnnx"
    static let shared = ASREngineRegistry(descriptors: [
        .sherpaOnnx,
        .apple,
        .volcengine,
    ])

    let descriptors: [ASREngineDescriptor]

    private let descriptorByCode: [String: ASREngineDescriptor]
    private let fallbackCode: String

    init(descriptors: [ASREngineDescriptor], fallbackCode: String = ASREngineRegistry.appleCode) {
        self.descriptors = descriptors
        self.fallbackCode = fallbackCode
        self.descriptorByCode = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.code, $0) })
    }

    func descriptor(for code: String) -> ASREngineDescriptor? {
        descriptorByCode[code]
    }

    func normalizedCode(for code: String?) -> String {
        guard let code, descriptorByCode[code] != nil else { return fallbackCode }
        return code
    }

    func isApple(_ code: String) -> Bool {
        code == Self.appleCode
    }

    func isSherpa(_ code: String) -> Bool {
        code == Self.sherpaCode
    }

    func isCloud(_ code: String) -> Bool {
        descriptor(for: code)?.requiresCredential == true
    }
}
