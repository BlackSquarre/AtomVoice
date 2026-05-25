import Cocoa

protocol OOBEStep: AnyObject {
    func makeView() -> NSView
    func willAppear()
    func willDisappear()
}

extension OOBEStep {
    func willAppear() {}
    func willDisappear() {}
}
