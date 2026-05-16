import CoreAudio
import Foundation

/// 检测当前系统默认输出设备是否为耳机/AirPods 等"耳机类"设备。
/// (Detect whether the current default audio output device is a headphone-like device — wired, USB, or AirPods.)
enum AudioOutputProbe {

    /// 返回 true 表示当前输出为耳机/AirPods/蓝牙耳机；返回 false 表示内置扬声器或 HDMI/外放等。
    /// (true → headphone-like output; false → built-in speakers, HDMI, etc.)
    static func isHeadphoneOutputActive() -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let transport = transportType(of: deviceID)

        switch transport {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay:
            // AirPods 等无线耳机
            return true

        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt:
            // USB / Thunderbolt 外接耳机或声卡（保守视为耳机类）
            return true

        case kAudioDeviceTransportTypeBuiltIn:
            // 内置：通过 data source 区分内置扬声器 vs 已插入的 3.5mm 耳机
            return builtInDataSourceIsHeadphones(deviceID: deviceID)

        default:
            return false
        }
    }

    // MARK: - 私有辅助

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    /// 内置音频设备的 data source 为 'hdpn' 时表示插入了 3.5mm 耳机。
    /// (Built-in device's data source 'hdpn' means a wired headphone is plugged into the jack.)
    private static func builtInDataSourceIsHeadphones(deviceID: AudioDeviceID) -> Bool {
        var dataSource = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &dataSource)
        guard status == noErr else { return false }
        // 'hdpn' = headphones, 'ispk' = internal speaker
        let headphoneCode: UInt32 = 0x6864_706E // 'hdpn'
        return dataSource == headphoneCode
    }
}
