import CoreAudio
import Foundation

struct Device {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int
}

func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else { return "<error \(status)>" }
    return value?.takeUnretainedValue() as String? ?? ""
}

func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else {
        return 0
    }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return status == noErr && id != 0 ? id : nil
}

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
    fatalError("Could not read CoreAudio device list")
}
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
    fatalError("Could not read CoreAudio devices")
}

let inputDefault = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let outputDefault = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let devices = ids.map {
    Device(
        id: $0,
        name: stringProperty($0, kAudioDevicePropertyDeviceNameCFString),
        uid: stringProperty($0, kAudioDevicePropertyDeviceUID),
        inputChannels: channelCount($0, scope: kAudioDevicePropertyScopeInput),
        outputChannels: channelCount($0, scope: kAudioDevicePropertyScopeOutput)
    )
}

print("Default input: \(inputDefault.map(String.init) ?? "nil")")
print("Default output: \(outputDefault.map(String.init) ?? "nil")")
for device in devices.sorted(by: { $0.id < $1.id }) {
    let inputMark = device.id == inputDefault ? "*" : " "
    let outputMark = device.id == outputDefault ? ">" : " "
    print("\(inputMark)\(outputMark) id=\(device.id) in=\(device.inputChannels) out=\(device.outputChannels) name=\(device.name) uid=\(device.uid)")
}
