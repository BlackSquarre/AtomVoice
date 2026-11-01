import Foundation

/// 主链路与自动恢复权限分别表达；恢复未就绪不会阻断可用的云端主链路。
struct PermissionRequirements {
    let primary: [PermissionKind]
    let recovery: [PermissionKind]

    static func forEngine(_ code: String) -> Self {
        let captureAndOutput: [PermissionKind] = [.accessibility, .microphone]
        switch code {
        case ASREngineRegistry.appleCode:
            return .init(primary: captureAndOutput + [.speechRecognition], recovery: [])
        case VolcengineASRSettings.engineCode:
            return .init(primary: captureAndOutput, recovery: [.speechRecognition])
        default:
            return .init(primary: captureAndOutput, recovery: [])
        }
    }

    // 保留原 OOBE 三卡与完成/后续启动的请求范围；收窄授权属于产品流程变更。
    static let onboarding: [PermissionKind] = [.accessibility, .microphone, .speechRecognition]
    static let startupRequests: [PermissionKind] = [.microphone, .speechRecognition]
}

struct PermissionReadiness {
    let primaryReady: Bool
    let recoveryReady: Bool
}
