import Foundation

final class OOBESelectionState {
    var engine: String = ASREngineRegistry.appleCode
    var triggerKeyCode: UInt16 = 61
    var silenceAutoStop: Bool = false
    var headphoneControl: Bool = false
}
