import AVFoundation
import Cocoa
import Foundation
import Security
@testable import AtomVoiceCore

enum PermissionTests {
    static func run(_ runner: inout TestRunner) async {
        await runner.run("Access kind maps card tags") {
            try expect(PermissionKind(permissionCardTag: 0) == .accessibility)
            try expect(PermissionKind(permissionCardTag: 1) == .microphone)
            try expect(PermissionKind(permissionCardTag: 2) == .speechRecognition)
            try expect(PermissionKind(permissionCardTag: -1) == nil)
            try expect(PermissionKind(permissionCardTag: 3) == nil)
        }
        await runner.run("Access gate ignores optional voice entitlement") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(service.hasRequiredPermissions(speechRequired: false))
        }
        await runner.run("Access gate requires voice entitlement when requested") {
            let access = FakePermissionAccess(statuses: [
                .accessibility: .granted,
                .microphone: .granted,
                .speechRecognition: .denied,
            ])
            let service = PermissionService(access: access)

            try expect(!service.hasRequiredPermissions(speechRequired: true))

            access.statuses[.speechRecognition] = .granted
            try expect(service.hasRequiredPermissions(speechRequired: true))
        }
        await runner.run("Access gate requests undetermined capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 1)
            try expect(access.openedSettings.isEmpty)
        }
        await runner.run("Access gate opens settings for denied capture access") {
            let access = FakePermissionAccess(statuses: [.microphone: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .microphone)

            try expect(access.requestedMicrophoneCount == 0)
            try expect(access.openedSettings == [.microphone])
        }
        await runner.run("Access gate requests undetermined dictation access") {
            let access = FakePermissionAccess(statuses: [.speechRecognition: .notDetermined])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .speechRecognition)

            try expect(access.requestedSpeechRecognitionCount == 1)
            try expect(access.openedSettings.isEmpty)
        }
        await runner.run("Access gate opens assistive-control settings") {
            let access = FakePermissionAccess(statuses: [.accessibility: .denied])
            let service = PermissionService(access: access)

            service.requestOrOpenSettings(for: .accessibility)

            try expect(access.openedSettings == [.accessibility])
        }
    }
}
