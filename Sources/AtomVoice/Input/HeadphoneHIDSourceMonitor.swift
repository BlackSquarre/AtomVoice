import Foundation
import IOKit.hid

struct HeadphoneHIDUsagePair: Equatable {
    let usagePage: Int
    let usage: Int
}

struct HeadphoneHIDDeviceDescriptor: Equatable {
    let transport: String?
    let vendorID: Int?
    let productID: Int?
    let locationID: Int?
    let manufacturer: String?
    let product: String?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let isBuiltIn: Bool
    let conformsToKeyboard: Bool
    let hasKeyboardPropertyHint: Bool
    let usagePairs: [HeadphoneHIDUsagePair]

    var diagnosticSummary: String {
        let name = product ?? "Unknown"
        let maker = manufacturer ?? "Unknown"
        let transportText = transport ?? "Unknown"
        let vendorText = vendorID.map { String(format: "0x%04X", $0) } ?? "nil"
        let productText = productID.map { String(format: "0x%04X", $0) } ?? "nil"
        let locationText = locationID.map { String(format: "0x%08X", $0) } ?? "nil"
        let primaryText = "\(primaryUsagePage ?? -1)/\(primaryUsage ?? -1)"
        let pairsText = usagePairs.map { "\($0.usagePage)/\($0.usage)" }.joined(separator: ",")
        return "product=\(name) manufacturer=\(maker) transport=\(transportText) vendor=\(vendorText) productID=\(productText) location=\(locationText) builtIn=\(isBuiltIn) conformsKeyboard=\(conformsToKeyboard) keyboardHint=\(hasKeyboardPropertyHint) primary=\(primaryText) pairs=[\(pairsText)]"
    }
}

struct HeadphoneHIDTrustDecision: Equatable {
    let isTrusted: Bool
    let reason: String
}

enum HeadphoneHIDSourceClassifier {
    static let genericDesktopPage = 0x01
    static let keyboardUsage = 0x06
    static let consumerPage = 0x0C
    static let consumerControlUsage = 0x01
    static let keyboardPage = 0x07
    static let playUsage = 0xB0
    static let pauseUsage = 0xB1
    static let playOrPauseUsage = 0xCD

    static func isPlayPauseUsage(usagePage: Int, usage: Int) -> Bool {
        guard usagePage == consumerPage else { return false }
        return usage == playUsage || usage == pauseUsage || usage == playOrPauseUsage
    }

    static func trustDecision(for descriptor: HeadphoneHIDDeviceDescriptor) -> HeadphoneHIDTrustDecision {
        guard isConsumerControlDevice(descriptor) else {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "not-consumer-control")
        }

        if descriptor.isBuiltIn {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "built-in-device")
        }

        if descriptor.conformsToKeyboard {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "keyboard-conformance")
        }

        if descriptor.hasKeyboardPropertyHint {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "keyboard-property")
        }

        if hasKeyboardUsage(descriptor) {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "keyboard-usage")
        }

        if isLikelyKeyboardName(descriptor) {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "keyboard-name")
        }

        if isAirPodsName(descriptor) {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "airpods-unsupported")
        }

        guard isTrustedTransport(descriptor) else {
            return HeadphoneHIDTrustDecision(isTrusted: false, reason: "unsupported-transport")
        }

        return HeadphoneHIDTrustDecision(isTrusted: true, reason: "trusted-non-keyboard-consumer-control")
    }

    private static func isConsumerControlDevice(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        if descriptor.primaryUsagePage == consumerPage,
           descriptor.primaryUsage == consumerControlUsage {
            return true
        }
        return descriptor.usagePairs.contains {
            $0.usagePage == consumerPage && $0.usage == consumerControlUsage
        }
    }

    private static func hasKeyboardUsage(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        if descriptor.primaryUsagePage == keyboardPage {
            return true
        }
        if descriptor.primaryUsagePage == genericDesktopPage,
           descriptor.primaryUsage == keyboardUsage {
            return true
        }
        return descriptor.usagePairs.contains {
            $0.usagePage == keyboardPage ||
            ($0.usagePage == genericDesktopPage && $0.usage == keyboardUsage)
        }
    }

    private static func isLikelyKeyboardName(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        let haystack = [
            descriptor.product,
            descriptor.manufacturer
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        guard !haystack.isEmpty else { return false }
        let keyboardTokens = [
            "keyboard",
            "magic keyboard",
            "keychron",
            "mx keys",
            "keypad",
            "kbd",
            "keyboard receiver",
            "usb receiver",
            "wireless receiver",
            "2.4g receiver",
            "unifying receiver",
            "bolt receiver"
        ]
        return keyboardTokens.contains { haystack.contains($0) }
    }

    private static func isAirPodsName(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        let haystack = [
            descriptor.product,
            descriptor.manufacturer
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return haystack.contains("airpods")
    }

    private static func isLikelyHeadsetName(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        let haystack = [
            descriptor.product,
            descriptor.manufacturer
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        guard !haystack.isEmpty else { return false }
        let headsetTokens = [
            "headset",
            "headphone",
            "headphones",
            "earphone",
            "earphones",
            "earbud",
            "earbuds"
        ]
        return headsetTokens.contains { haystack.contains($0) }
    }

    private static func isTrustedTransport(_ descriptor: HeadphoneHIDDeviceDescriptor) -> Bool {
        guard let transport = descriptor.transport else { return false }
        let normalized = transport.lowercased()
        if normalized == "usb" ||
            normalized == "bluetooth" ||
            normalized == "bluetoothlowenergy" {
            return true
        }

        // 3.5mm 有线耳机线控在 Apple 机器上会作为 transport=Audio 的 Consumer Control 出现。
        // 只在设备名称也明确像耳机时放行 Play/Pause；音量键和其它媒体键仍由 HeadphoneMonitor 放行。
        return normalized == "audio" && isLikelyHeadsetName(descriptor)
    }
}

/// 从 IOHID 层记录最近一次可信的耳机 Play/Pause 来源。
///
/// CGEvent/NSEvent 层只暴露 NX_KEYTYPE_PLAY，无法说明事件来自键盘还是耳机。
/// 这里用更底层的 HID device 属性做“来源证明”：只有非键盘 Consumer Control 设备
/// 在短时间窗口内发过 Play/Pause，HeadphoneMonitor 才允许接管对应 CGEvent。
final class HeadphoneHIDSourceMonitor {
    private var manager: IOHIDManager?
    private var lastTrustedPlayPauseTime: CFAbsoluteTime = 0
    private var lastTrustedSummary: String?
    private var lastRejectedSummary: String?

    func start() {
        guard manager == nil else { return }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey: HeadphoneHIDSourceClassifier.consumerPage,
                kIOHIDDeviceUsageKey: HeadphoneHIDSourceClassifier.consumerControlUsage
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(
            hidManager,
            HeadphoneHIDSourceMonitor.inputValueCallback,
            Unmanaged.passRetained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let status = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            IOHIDManagerRegisterInputValueCallback(hidManager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            Unmanaged<HeadphoneHIDSourceMonitor>.passUnretained(self).release()
            DebugLog.error("[HeadphoneHIDSource] IOHIDManager 启动失败 status=\(status)")
            return
        }

        manager = hidManager
        DebugLog.info("[HeadphoneHIDSource] 已启动 Consumer Control 来源监视")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // 释放 start() 中 passRetained 的强引用（Release the retained reference from start()）
        Unmanaged<HeadphoneHIDSourceMonitor>.passUnretained(self).release()
        self.manager = nil
        lastTrustedPlayPauseTime = 0
        lastTrustedSummary = nil
        lastRejectedSummary = nil
        DebugLog.info("[HeadphoneHIDSource] 已停止")
    }

    func hasRecentTrustedPlayPauseEvent(within interval: TimeInterval) -> Bool {
        guard lastTrustedPlayPauseTime > 0 else { return false }
        let age = CFAbsoluteTimeGetCurrent() - lastTrustedPlayPauseTime
        let recent = age <= interval
        if recent {
            DebugLog.info("[HeadphoneHIDSource] 命中可信来源窗口 age=\(String(format: "%.3f", age))s source=\(lastTrustedSummary ?? "nil")")
        } else {
            DebugLog.info("[HeadphoneHIDSource] 未命中可信来源窗口 age=\(String(format: "%.3f", age))s lastTrusted=\(lastTrustedSummary ?? "nil") lastRejected=\(lastRejectedSummary ?? "nil")")
        }
        return recent
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let monitor = Unmanaged<HeadphoneHIDSourceMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handleInputValue(value)
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard HeadphoneHIDSourceClassifier.isPlayPauseUsage(usagePage: usagePage, usage: usage) else {
            return
        }
        guard IOHIDValueGetIntegerValue(value) != 0 else {
            return
        }
        let device = IOHIDElementGetDevice(element)

        let descriptor = Self.deviceDescriptor(from: device)
        let decision = HeadphoneHIDSourceClassifier.trustDecision(for: descriptor)
        if decision.isTrusted {
            lastTrustedPlayPauseTime = CFAbsoluteTimeGetCurrent()
            lastTrustedSummary = descriptor.diagnosticSummary
            DebugLog.info("[HeadphoneHIDSource] 可信 Play/Pause 来源：reason=\(decision.reason) \(descriptor.diagnosticSummary)")
        } else {
            lastRejectedSummary = "\(decision.reason) \(descriptor.diagnosticSummary)"
            DebugLog.info("[HeadphoneHIDSource] 拒绝 Play/Pause 来源：reason=\(decision.reason) \(descriptor.diagnosticSummary)")
        }
    }

    private static func deviceDescriptor(from device: IOHIDDevice) -> HeadphoneHIDDeviceDescriptor {
        let primaryUsagePage = intProperty(device, key: kIOHIDPrimaryUsagePageKey)
        let primaryUsage = intProperty(device, key: kIOHIDPrimaryUsageKey)
        var pairs = usagePairsProperty(device)
        if pairs.isEmpty,
           let primaryUsagePage,
           let primaryUsage {
            pairs.append(HeadphoneHIDUsagePair(usagePage: primaryUsagePage, usage: primaryUsage))
        }

        return HeadphoneHIDDeviceDescriptor(
            transport: stringProperty(device, key: kIOHIDTransportKey),
            vendorID: intProperty(device, key: kIOHIDVendorIDKey),
            productID: intProperty(device, key: kIOHIDProductIDKey),
            locationID: intProperty(device, key: kIOHIDLocationIDKey),
            manufacturer: stringProperty(device, key: kIOHIDManufacturerKey),
            product: stringProperty(device, key: kIOHIDProductKey),
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            isBuiltIn: boolProperty(device, key: kIOHIDBuiltInKey),
            conformsToKeyboard: IOHIDDeviceConformsTo(
                device,
                UInt32(HeadphoneHIDSourceClassifier.genericDesktopPage),
                UInt32(HeadphoneHIDSourceClassifier.keyboardUsage)
            ),
            hasKeyboardPropertyHint: hasKeyboardPropertyHint(device),
            usagePairs: pairs
        )
    }

    private static func hasKeyboardPropertyHint(_ device: IOHIDDevice) -> Bool {
        let keys = [
            kIOHIDKeyboardLanguageKey,
            kFnKeyboardUsageMapKey,
            kNumLockKeyboardUsageMapKey,
            kKeyboardUsageMapKey,
            kIOHIDKeyboardLayoutValueKey,
            kIOHIDKeyboardFunctionKeyCountKey,
            "SupportedKeyboardUsagePairs"
        ]
        return keys.contains { IOHIDDeviceGetProperty(device, $0 as CFString) != nil }
    }

    private static func usagePairsProperty(_ device: IOHIDDevice) -> [HeadphoneHIDUsagePair] {
        guard let raw = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) else {
            return []
        }
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let page = anyInt(item[kIOHIDDeviceUsagePageKey]),
                  let usage = anyInt(item[kIOHIDDeviceUsageKey]) else {
                return nil
            }
            return HeadphoneHIDUsagePair(usagePage: page, usage: usage)
        }
    }

    private static func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        anyInt(IOHIDDeviceGetProperty(device, key as CFString))
    }

    private static func boolProperty(_ device: IOHIDDevice, key: String) -> Bool {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func anyInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
