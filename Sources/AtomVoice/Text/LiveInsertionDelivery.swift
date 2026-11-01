import Foundation

/// 每轮实时投递的发送记账。结果可晚于下一轮录音，不能借用下一轮的状态。
final class LiveInsertionDelivery {
    private(set) var committedText = ""
    private(set) var pendingSegment: String?
    private var waiters: [(String) -> Void] = []

    func begin(_ segment: String) {
        pendingSegment = segment
    }

    @discardableResult
    func resolve(_ result: TextDeliveryResult) -> Bool {
        guard let segment = pendingSegment else { return false }
        pendingSegment = nil
        if result.submission == .eventPosted { committedText += segment }
        let completions = waiters
        waiters.removeAll()
        completions.forEach { $0(committedText) }
        return true
    }

    func whenResolved(_ completion: @escaping (String) -> Void) {
        if pendingSegment == nil { completion(committedText) }
        else { waiters.append(completion) }
    }
}
