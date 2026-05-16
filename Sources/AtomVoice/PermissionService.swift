import Cocoa
import AVFoundation
import Speech
import ApplicationServices

enum PermissionStatus: Equatable {
    case granted, denied, notDetermined

    var color: NSColor {
        switch self {
        case .granted:       return NSColor(red: 0.15, green: 0.78, blue: 0.33, alpha: 1)
        case .denied:        return .systemRed
        case .notDetermined: return .systemOrange
        }
    }

    var label: String {
        switch self {
        case .granted:       return loc("permission.status.granted")
        case .denied:        return loc("permission.status.denied")
        case .notDetermined: return loc("permission.status.notDetermined")
        }
    }
}

enum PermissionKind: Equatable {
    case accessibility
    case microphone
    case speechRecognition

    init?(permissionCardTag tag: Int) {
        switch tag {
        case 0: self = .accessibility
        case 1: self = .microphone
        case 2: self = .speechRecognition
        default: return nil
        }
    }
}

protocol PermissionAccessing: AnyObject {
    func status(for kind: PermissionKind) -> PermissionStatus
    func requestMicrophone(completion: @escaping (Bool) -> Void)
    func requestSpeechRecognition(completion: @escaping (Bool) -> Void)
    func openSettings(for kind: PermissionKind)
}

final class SystemPermissionAccess: PermissionAccessing {
    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        }
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func requestSpeechRecognition(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = settingsURL(for: kind) else { return }
        NSWorkspace.shared.open(url)
    }

    private func settingsURL(for kind: PermissionKind) -> URL? {
        switch kind {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        }
    }
}

final class PermissionService {
    static let shared = PermissionService(access: SystemPermissionAccess())

    private let access: PermissionAccessing

    init(access: PermissionAccessing) {
        self.access = access
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        access.status(for: kind)
    }

    func hasRequiredPermissions(speechRequired: Bool) -> Bool {
        status(for: .accessibility) == .granted &&
        status(for: .microphone) == .granted &&
        (!speechRequired || status(for: .speechRecognition) == .granted)
    }

    func requestOrOpenSettings(for kind: PermissionKind, completion: (() -> Void)? = nil) {
        switch kind {
        case .accessibility:
            openSettings(for: kind)
            completion?()
        case .microphone:
            if status(for: kind) == .notDetermined {
                access.requestMicrophone { _ in
                    DispatchQueue.main.async { completion?() }
                }
            } else {
                openSettings(for: kind)
                completion?()
            }
        case .speechRecognition:
            if status(for: kind) == .notDetermined {
                access.requestSpeechRecognition { _ in
                    DispatchQueue.main.async { completion?() }
                }
            } else {
                openSettings(for: kind)
                completion?()
            }
        }
    }

    func openSettings(for kind: PermissionKind) {
        access.openSettings(for: kind)
    }

    func requestStartupPermissions(alertPresenter: AlertPresenting = AlertPresenter.shared) {
        access.requestMicrophone { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.mic.title")
                    alert.informativeText = loc("permission.mic.message")
                    alertPresenter.runModalAlert(alert)
                }
            }
        }

        access.requestSpeechRecognition { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = loc("permission.speech.requiredTitle")
                    alert.informativeText = loc("permission.speech.message")
                    alertPresenter.runModalAlert(alert)
                }
            }
        }
    }
}
